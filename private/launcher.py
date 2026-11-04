#!/usr/bin/env python3
"""vault_server launcher.

  launcher.py --vault BIN --env-file PATH --state-dir DIR
              --ready-timeout SECONDS --root-token TOKEN
              [--secrets-engine PATH=TYPE]... [--auth-method PATH=TYPE]...
              [--policy NAME=FILE]... [--setup FILE]... [--audit]
              [-- EXTRA_VAULT_SERVER_FLAGS...]

1. Picks a free port P (with P+1 free too: dev mode puts its cluster
   listener there) and starts `vault server -dev` on 127.0.0.1:P with the
   given root token. Retries with new ports on a clash, up to 5 times.
2. Polls GET /v1/sys/health until it answers 200 (initialized, unsealed,
   active) or --ready-timeout passes. If vault exits or never becomes
   healthy, the launcher fails, naming Vault and printing its log.
3. Configures it with the vault CLI, in this order: secrets engines, auth
   methods, policies, the file audit device (only with --audit), then each
   --setup script. Setup scripts get VAULT_ADDR, VAULT_TOKEN, VAULT (the
   binary), `vault` on PATH, and VAULT_EXPORT_FILE: lines `NAME=VALUE`
   appended there are added to the env file. A failing step stops vault
   and fails the launcher, naming the step.
4. Writes the env file atomically (tmp + rename):
     VAULT_ADDR=http://127.0.0.1:<port>
     VAULT_TOKEN=<root token>
     VAULT_HOST=127.0.0.1
     VAULT_PORT=<port>
     VAULT=<absolute path to the vault binary>
     VAULT_AUDIT_LOG=<path>          (only with --audit)
     <exports from setup scripts>
5. Waits. SIGTERM / SIGINT stops vault, removes the env file and exits 0;
   if vault dies, exits with its status.
"""

import argparse
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

_EXPORT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


class Failed(Exception):
    """A start or setup step failed; the message names it."""


def _log(msg):
    print(f"[vault_server] {msg}", file=sys.stderr, flush=True)


def _port_pair():
    """A port P where P and P+1 were both free a moment ago."""
    for _ in range(50):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        t = socket.socket()
        try:
            t.bind(("127.0.0.1", port + 1))
        except OSError:
            continue
        finally:
            t.close()
            s.close()
        return port
    raise Failed("no free pair of adjacent ports for vault's API and cluster listeners")


def _healthy(addr):
    try:
        with urllib.request.urlopen(addr + "/v1/sys/health", timeout=2) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _server_env(state_dir):
    """The launcher's environment without VAULT_* (a consumer's VAULT_ADDR
    or VAULT_TOKEN must not leak into the server), with HOME in the state
    dir so vault's cache stays out of the user's home."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("VAULT_")}
    env["HOME"] = os.path.join(state_dir, "home")
    os.makedirs(env["HOME"], exist_ok=True)
    return env


def _log_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return "(no log)"


def start(args, procs):
    """Start vault and wait until healthy. Returns (proc, port). The proc
    is appended to `procs` as soon as it exists, so a signal can stop it."""
    log_path = os.path.join(args.state_dir, "vault.log")
    for attempt in range(1, 6):
        port = _port_pair()
        addr = f"http://127.0.0.1:{port}"
        cmd = [
            args.vault, "server", "-dev",
            f"-dev-root-token-id={args.root_token}",
            f"-dev-listen-address=127.0.0.1:{port}",
            "-dev-no-store-token",
        ] + args.extra
        with open(log_path, "w") as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL,
                                    env=_server_env(args.state_dir))
        procs.append(proc)
        deadline = time.monotonic() + args.ready_timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            if _healthy(addr):
                return proc, port
            time.sleep(0.1)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
            raise Failed(f"Vault was not healthy (GET /v1/sys/health) within "
                         f"{args.ready_timeout:g}s at {addr}. Vault log:\n"
                         + _log_text(log_path))
        out = _log_text(log_path)
        if "address already in use" in out and attempt < 5:
            _log(f"port {port} or {port + 1} taken (attempt {attempt}); retrying")
            continue
        raise Failed(f"Vault exited with status {proc.returncode} before it was "
                     f"healthy. Vault log:\n{out}")
    raise Failed("Vault could not get a free port after 5 attempts")


def _client_env(args, addr, export_file):
    env = dict(os.environ)
    env.update({
        "VAULT_ADDR": addr,
        "VAULT_TOKEN": args.root_token,
        "VAULT": os.path.abspath(args.vault),
        "VAULT_EXPORT_FILE": export_file,
        "PATH": os.path.dirname(os.path.abspath(args.vault)) + os.pathsep
                + os.environ.get("PATH", ""),
    })
    for k in ("VAULT_NAMESPACE", "VAULT_CACERT", "VAULT_CLIENT_CERT",
              "VAULT_CLIENT_KEY", "VAULT_SKIP_VERIFY"):
        env.pop(k, None)
    return env


def _run(what, cmd, env):
    """Run one configuration step; output goes to stderr. Raises Failed
    naming the step."""
    r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL,
                       stdout=sys.stderr, stderr=sys.stderr)
    if r.returncode != 0:
        raise Failed(f"{what} failed with status {r.returncode}")


def _split(spec, flag):
    key, sep, value = spec.partition("=")
    if not sep or not key or not value:
        raise Failed(f"{flag} {spec!r}: expected PATH=TYPE")
    return key, value


def configure(args, env, audit_log):
    vault = os.path.abspath(args.vault)
    for spec in args.secrets_engine:
        path, typ = _split(spec, "--secrets-engine")
        _run(f"enabling secrets engine {typ} at {path}/",
             [vault, "secrets", "enable", f"-path={path}", typ], env)
    for spec in args.auth_method:
        path, typ = _split(spec, "--auth-method")
        _run(f"enabling auth method {typ} at {path}/",
             [vault, "auth", "enable", f"-path={path}", typ], env)
    for spec in args.policy:
        name, path = _split(spec, "--policy")
        _run(f"writing policy {name} ({path})",
             [vault, "policy", "write", name, path], env)
    if audit_log:
        _run("enabling the file audit device",
             [vault, "audit", "enable", "file", f"file_path={audit_log}"], env)
    for script in args.setup:
        cmd = [script] if os.access(script, os.X_OK) else ["bash", script]
        _log(f"setup: {script}")
        _run(f"setup script {script}", cmd, env)


def read_exports(path):
    """Parse NAME=VALUE lines written by setup scripts."""
    exports = {}
    if not os.path.exists(path):
        return exports
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = _EXPORT.match(line)
            if not m:
                raise Failed(f"VAULT_EXPORT_FILE line {n}: expected NAME=VALUE, got {line!r}")
            exports[m.group(1)] = m.group(2)
    return exports


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={shlex.quote(str(v))}\n")
    os.replace(tmp, env_file)


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--vault", required=True)
    p.add_argument("--env-file", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--ready-timeout", type=float, default=30.0)
    p.add_argument("--root-token", default="root")
    p.add_argument("--secrets-engine", action="append", default=[])
    p.add_argument("--auth-method", action="append", default=[])
    p.add_argument("--policy", action="append", default=[])
    p.add_argument("--setup", action="append", default=[])
    p.add_argument("--audit", action="store_true")
    p.add_argument("extra", nargs="*")
    args = p.parse_args(argv)
    if not 0 < args.ready_timeout < float("inf"):
        _log(f"--ready-timeout must be a positive number of seconds, got {args.ready_timeout}")
        return 1
    if not args.root_token:
        _log("--root-token must not be empty")
        return 1

    os.makedirs(args.state_dir, exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass

    # Installed before vault starts, so a signal during start-up or setup
    # still stops it. The handler only asks vault to stop: once ready, the
    # main thread is blocked in proc.wait(), which holds Popen's wait lock,
    # so waiting here as well would stall until a timeout.
    procs = []
    stopping = []
    ready = []

    def _stop(signum, _frame):
        if stopping:
            return
        _log(f"signal {signum}; stopping")
        stopping.append(signum)
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
                killer = threading.Timer(10, proc.kill)
                killer.daemon = True
                killer.start()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    proc = None
    try:
        proc, port = start(args, procs)
        addr = f"http://127.0.0.1:{port}"
        export_file = os.path.join(args.state_dir, "exports.env")
        open(export_file, "w").close()
        audit_log = os.path.join(args.state_dir, "audit.log") if args.audit else None
        configure(args, _client_env(args, addr, export_file), audit_log)
        values = {
            "VAULT_ADDR": addr,
            "VAULT_TOKEN": args.root_token,
            "VAULT_HOST": "127.0.0.1",
            "VAULT_PORT": port,
            "VAULT": os.path.abspath(args.vault),
        }
        if audit_log:
            values["VAULT_AUDIT_LOG"] = audit_log
        values.update(read_exports(export_file))
        write_env(args.env_file, values)
        ready.append(True)
    except Failed as e:
        _log(str(e))
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()
            _log("Vault log:\n" + _log_text(os.path.join(args.state_dir, "vault.log")))
        return 1
    except SystemExit:
        for pr in procs:
            if pr.poll() is None:
                pr.kill()
                pr.wait()
        raise

    _log(f"ready at {addr}; env file {args.env_file}")
    rc = proc.wait()
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass
    if stopping:
        return 0
    _log(f"vault exited with status {rc}. Vault log:\n"
         + _log_text(os.path.join(args.state_dir, "vault.log")))
    return rc or 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

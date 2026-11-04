"""Vault binary pins.

One HashiCorp release zip per platform, holding the single `vault`
binary (server and CLI in one):

    https://releases.hashicorp.com/vault/<ver>/vault_<ver>_<os>_<arch>.zip

SHA-256s are the release's published `vault_<ver>_SHA256SUMS`.
Maintainer flow:

    tools/update_checksums.sh <ver>     # add / re-pin <ver> from SHA256SUMS
    tools/update_checksums.sh --check   # verify every pin, no writes

//tests:checksums_test fails on an empty or malformed value.
"""

VAULT_VERSIONS = {
    "1.21.2": {
        "linux_amd64": {
            "url": "https://releases.hashicorp.com/vault/1.21.2/vault_1.21.2_linux_amd64.zip",
            "sha256": "d2005a053a2ab75318d395ca8151aef9116fde67f75dc8f43a4fa9def6f3fc9e",
        },
        "linux_arm64": {
            "url": "https://releases.hashicorp.com/vault/1.21.2/vault_1.21.2_linux_arm64.zip",
            "sha256": "27dc55533a201be4c427319a31caa3ca330cfd40b158d111f22a1dee94ae1f17",
        },
        "darwin_amd64": {
            "url": "https://releases.hashicorp.com/vault/1.21.2/vault_1.21.2_darwin_amd64.zip",
            "sha256": "1bb297df6230212764f24df88b3123419c49be6528743cffcaf8d676547634dc",
        },
        "darwin_arm64": {
            "url": "https://releases.hashicorp.com/vault/1.21.2/vault_1.21.2_darwin_arm64.zip",
            "sha256": "d197adcb303cb527834774e19d6a67abcefb11cc9c57bd42f5bcdd4a1b21be9c",
        },
    },
}

PLATFORMS = {
    "linux_amd64":  ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64":  ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx",   "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx",   "@platforms//cpu:arm64"],
}

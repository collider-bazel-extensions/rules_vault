# The onboarding worker: reads its app config, issues installation
# certificates, and mints renewal tokens through the `renewal` token role.
path "secret/data/app/*" {
  capabilities = ["read"]
}

path "pki/issue/installations" {
  capabilities = ["create", "update"]
}

path "auth/token/create/renewal" {
  capabilities = ["create", "update"]
}

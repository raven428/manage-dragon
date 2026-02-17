path "secret/data/%s/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/%s/*" {
  capabilities = ["read", "list", "delete"]
}

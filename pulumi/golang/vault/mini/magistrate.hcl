path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/leases/lookup" {
  capabilities = ["list", "sudo"]
}

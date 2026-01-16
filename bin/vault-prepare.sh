#!/usr/bin/env bash
# admin policy
cat <<EOF | vault policy write pol-magistrate -
# Global wildcard for most things
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
# Override default policy specificity for leases
path "sys/leases/lookup" {
  capabilities = ["list", "sudo"]
}
EOF
for group in green-wire green-mercs manage-dragon; do
  cat <<EOF | vault policy write gr-read-${group} -
path "secret/data/${group}/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/${group}/*" {
  capabilities = ["read", "list"]
}
EOF
  cat <<EOF | vault policy write gr-admin-${group} -
path "secret/data/${group}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/${group}/*" {
  capabilities = ["read", "list", "delete"]
}
EOF
done
vault audit enable syslog tag='vaudit' facility="AUTH"
vault auth enable userpass
for admin in raven magister; do
  vault write auth/userpass/users/${admin} password=secret
  # Get or create the entity and capture its ID:
  E_ID=$(vault read -field=id identity/entity/name/ent-${admin} 2>/dev/null)
  [[ -z "${E_ID}" ]] && E_ID=$(vault write -format=json identity/entity \
    name="ent-${admin}" metadata='role=overlord' | jq -r '.data.id')
  # Create or update the alias for the entity:
  vault write identity/entity-alias name="${admin}" canonical_id="${E_ID}" \
    mount_accessor="$(vault auth list -format=json | jq -r '."userpass/".accessor')"
  # Create or update the group:
  vault write identity/group name='gr-magistrate' policies='pol-magistrate' \
    member_entity_ids="${E_ID}"
done
vault secrets enable -version=2 -path=values kv

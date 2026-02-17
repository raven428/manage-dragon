MAGISTRATE = '''
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/leases/lookup" {
  capabilities = ["list", "sudo"]
}
'''

TEMPLATE_READ = '''
path "secret/data/{group}/*" {{
  capabilities = ["read","list"]
}}
path "secret/metadata/{group}/*" {{
  capabilities = ["read","list"]
}}
'''

TEMPLATE_ADMIN = '''
path "secret/data/{group}/*" {{
  capabilities = ["create","read","update","delete","list"]
}}
path "secret/metadata/{group}/*" {{
  capabilities = ["read","list","delete"]
}}
'''

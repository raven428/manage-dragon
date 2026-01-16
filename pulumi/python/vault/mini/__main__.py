from __future__ import annotations

import json
import secrets
import string
from typing import cast

# pylint: disable=import-error
import defs  # type: ignore[reportMissingImports]

# pylint: disable=import-error
import policies  # type: ignore[reportMissingImports]
import pulumi_vault as vault

import pulumi

config = pulumi.Config()
stack = pulumi.get_stack()
userpass_data = defs.vault_get(
  url='v1/sys/auth',
  path=['data'],
  expr=lambda k, v: v.get('type') == 'userpass' and k == 'userpass/',
)
opts: pulumi.ResourceOptions | None = (
  pulumi.ResourceOptions(import_='userpass') if stack != 'auth' or userpass_data else None
)
userpass_auth = vault.AuthBackend(
  'userpass',
  type='userpass',
  opts=opts,
)
if stack == 'auth':
  pulumi.export('auth backend', userpass_auth)
else:
  # Defined groups:
  groups = config.require_object('groups')
  for g in groups:
    defs.ensure_group(
      group_suffix=f'read-{g}',
      policy_body=policies.TEMPLATE_READ.format(group=g),
    )
    defs.ensure_group(
      group_suffix=f'admin-{g}',
      policy_body=policies.TEMPLATE_ADMIN.format(group=g),
    )
  audit_data = defs.vault_get(
    url='v1/sys/audit',
    path=['data'],
    expr=lambda k, v: v.get('type') == 'syslog' and k == 'syslog/',
  )
  # Audit:
  opts = (pulumi.ResourceOptions(import_='syslog') if audit_data else None)
  vault.Audit(
    'syslog',
    type='syslog',
    options={
      'tag': 'vaudit',
      'facility': 'AUTH',
    },
    opts=opts,
  )
  admin_entities = []
  for admin in config.require_object('admins'):
    user_data = None
    password = ''.join(
      secrets.choice(string.ascii_letters + string.digits + string.punctuation)
      for _ in range(secrets.choice(range(44, 55)))
    )
    # User and password
    try:
      user_data = vault.generic.get_secret(path=f'auth/userpass/users/{admin}')
    except Exception:  # noqa: BLE001
      pulumi.log.info(f'No user [{admin}] found…')
    vault.generic.Secret(
      f'user-password-{admin}',
      path=f'auth/userpass/users/{admin}',
      data_json=json.dumps({
        'password': password,
      }),
      opts=pulumi.ResourceOptions(
        ignore_changes=['data_json'] if user_data else None,
        depends_on=[userpass_auth],
      ),
    )
    # Entity for group:
    existing_entity = None
    try:
      existing_entity = vault.identity.get_entity(entity_name=f'ent-{admin}')
      pulumi.log.info(f'Entity [ent-{admin}] id [{existing_entity.entity_id}] catchup…')
    except Exception:  # noqa: BLE001
      pulumi.log.info(f'No entity [ent-{admin}] found…')
    opts = (
      pulumi.ResourceOptions(import_=existing_entity.entity_id)
      if existing_entity else None
    )
    entity = vault.identity.Entity(
      f'ent-{admin}',
      name=f'ent-{admin}',
      metadata={
        'role': 'overlord',
      },
      opts=opts,
    )
    admin_entities.append(entity.id)
    # Entity alias for user:
    alias_id = None
    try:
      existing_entity_id = existing_entity.id if existing_entity is not None else None
      found_entity = cast(
        'vault.identity.GetEntityResult',
        vault.identity.get_entity(entity_id=existing_entity_id),
      )
      alias_id = next(
        a['id'] for a in found_entity.aliases
        if a['mount_accessor'] == userpass_data.get('accessor')
      )
      pulumi.log.info(f'Alias [{admin}] id [{alias_id}] catchup…')
    except Exception:  # noqa: BLE001
      pulumi.log.info(f'No alias [{admin}] found…')
    opts = (pulumi.ResourceOptions(import_=alias_id) if alias_id else None)
    vault.identity.EntityAlias(
      f'als-{admin}',
      name=admin,
      canonical_id=entity.id,
      mount_accessor=userpass_data.get('accessor'),
      opts=opts,
    )
  # Admin group:
  defs.ensure_group(
    group_suffix='magistrate',
    policy_body=policies.MAGISTRATE,
    member_entity_ids=admin_entities,
  )
  # Key-value storage:
  storage_data = defs.vault_get(
    url='v1/sys/mounts',
    path=['data'],
    expr=lambda k, v: v.get('type') == 'kv' and k == 'depot/',
  )
  opts = (pulumi.ResourceOptions(import_='depot') if storage_data else None)
  depot_mount = vault.Mount(
    'v2kv-depot-mount',
    path='depot',
    type='kv',
    options={
      'version': '2',
    },
    opts=opts,
  )
  depot_config = vault.kv.SecretBackendV2(
    'v2kv-depot-config',
    mount='depot',
    max_versions=555,
    cas_required=True,
    delete_version_after=0,
    opts=pulumi.ResourceOptions(depends_on=[depot_mount]),
  )

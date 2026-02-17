from __future__ import annotations

import os
from typing import Any, Callable

import pulumi_vault as vault
import requests

import pulumi


def vault_get(
  url: str,
  path: list[str] | None = None,
  expr: Callable[[str, dict[str, Any]], bool] | None = None,
) -> dict[str, Any]:
  r = requests.get(
    f'{os.environ.get("VAULT_ADDR")}/{url}',
    headers={
      'X-Vault-Token': os.environ.get('VAULT_TOKEN'),
    },
    timeout=3,
  )
  j = r.json()
  target: Any = j
  if path:
    for key in path:
      target = target.get(key, {})
      if not isinstance(target, dict):
        return {}
  if expr is None:

    def expr_def(k: str, v: dict[str, Any]) -> bool:  # noqa: ARG001
      return False

    expr = expr_def

  return next((v for k, v in target.items() if expr(k, v)), {})


def ensure_group(
  group_suffix: str,
  policy_body: str,
  member_entity_ids: list[str] | None = None,
) -> None:
  vault.Policy(
    f'pol-{group_suffix}',
    name=f'pol-{group_suffix}',
    policy=policy_body,
  )
  group_name = f'gr-{group_suffix}'
  group_id = None
  try:
    existing_group = vault.identity.get_group(group_name=group_name)
    group_id = existing_group.group_id
    pulumi.log.info(f'Group [{group_name}] id [{group_id}] catchup…')
  except Exception:  # noqa: BLE001
    pulumi.log.info(f'No group [{group_name}] found…')
  args: dict[str, Any] = {
    'name': group_name,
    'policies': [f'pol-{group_suffix}'],
  }
  if member_entity_ids:
    args['member_entity_ids'] = member_entity_ids
  opts: pulumi.ResourceOptions | None = None
  if group_id:
    opts = pulumi.ResourceOptions(import_=group_id)
  vault.identity.Group(group_name, **args, opts=opts)

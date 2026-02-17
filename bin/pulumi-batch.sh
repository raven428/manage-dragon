#!/usr/bin/env bash
set -ueo pipefail
umask 0022
export PULUMI_CONFIG_PASSPHRASE=''
export PULUMI_SKIP_UPDATE_CHECK=true
/usr/bin/env pulumi login --local
/usr/bin/env pulumi stack select auth || pulumi stack init auth --non-interactive
/usr/bin/env pulumi stack select main || pulumi stack init main --non-interactive
# dir2venv="${HOME}/.pulumi/${PWD#*pulumi/}"
# /usr/bin/env mkdir -vp "${dir2venv}"
# /usr/bin/env ln -s "${dir2venv}" venv
/usr/bin/env pulumi up -y -s auth
/usr/bin/env pulumi up -y

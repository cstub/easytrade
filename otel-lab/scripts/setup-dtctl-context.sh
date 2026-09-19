#!/usr/bin/env bash
# Creates/updates the lab's read-only dtctl context. The token is NOT stored: the config references the
# environment variable EASYTRADE_OTEL_LAB_DT_TOKEN, which scripts/dtctl-lab.sh exports from the token file.
set -euo pipefail
CFG="${EASYTRADE_LAB_CONFIG_DIR:-$HOME/.config/easytrade-otel-lab}"
PLATFORM_URL="$(jq -r '.platform_url' "$CFG/lab.json")"
CTX="${DTCTL_LAB_CONTEXT:-easytrade-otel-lab}"
export DTCTL_TOKEN_STORAGE=file
dtctl config set-context "$CTX" --global --environment "$PLATFORM_URL" --token-ref "$CTX-token" \
  --safety-level readonly --description "EasyTrade OTel lab (read-only DQL validation)"
dtctl config set-credentials "$CTX-token" --global --token 'placeholder'
DTCFG="${XDG_CONFIG_HOME:-$HOME/.config}/dtctl/config"
python3 - "$DTCFG" "$CTX-token" <<'PY'
import sys,re
p,name=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'(- name: %s\n\s+token: )\S+' % re.escape(name), r'\1${EASYTRADE_OTEL_LAB_DT_TOKEN}', s)
open(p,'w').write(s)
PY
chmod 0600 "$DTCFG"
echo "context $CTX configured in $DTCFG (token via \$EASYTRADE_OTEL_LAB_DT_TOKEN)"
"$(dirname "$0")/dtctl-lab.sh" doctor --plain | sed 's/dt0s16\.[A-Za-z0-9.]*/<redacted>/g' || true

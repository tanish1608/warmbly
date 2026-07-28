#!/usr/bin/env bash
# Store an OAuth client id/secret pair as new Secret Manager versions.
#   ./set-oauth-secret.sh box-google <client-id> <client-secret>   # mailbox client
#   ./set-oauth-secret.sh google     <client-id> <client-secret>   # login client
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

kind="${1:?usage: set-oauth-secret.sh <box-google|google> <client-id> <client-secret>}"
client_id="${2:?missing client id}"
client_secret="${3:?missing client secret}"

case "$kind" in
  box-google|google) ;;
  *) echo "kind must be box-google or google" >&2; exit 1 ;;
esac

printf '%s' "$client_id"     | gc secrets versions add "warmbly-${kind}-client-id" --data-file=- >/dev/null
printf '%s' "$client_secret" | gc secrets versions add "warmbly-${kind}-client-secret" --data-file=- >/dev/null
echo "stored warmbly-${kind}-client-id / -client-secret"
echo "redeploy to pick them up:  ./07-deploy-run.sh && ./08-vm-services.sh"

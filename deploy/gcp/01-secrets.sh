#!/usr/bin/env bash
# Generate every Warmbly secret once and store it in Secret Manager.
# Idempotent: a secret that already exists is left untouched, because rotating
# CREDENTIALS_ENCRYPTION_KEY or KMS_LOCAL_MASTER_KEY makes every connected
# mailbox unrecoverable.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# name -> generator. Values are only generated when the secret does not exist.
put() {
  local name="$1" value="$2"
  if gc secrets describe "$name" >/dev/null 2>&1; then
    echo "  = $name (exists, unchanged)"
    return
  fi
  printf '%s' "$value" | gc secrets create "$name" --data-file=- --replication-policy=automatic >/dev/null
  echo "  + $name (created)"
}

echo "Secrets in ${PROJECT_ID}:"
put warmbly-auth-secret              "$(openssl rand -hex 32)"
put warmbly-credentials-encryption-key "$(openssl rand -hex 32)"   # 64 hex chars, seals mailbox creds
put warmbly-kms-local-master-key     "$(openssl rand -base64 32)"  # envelope-encryption root
put warmbly-internal-api-token       "$(openssl rand -hex 32)"
put warmbly-secret-key-base          "$(openssl rand -hex 48)"     # Phoenix, needs >= 64 chars
put warmbly-db-password              "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

# OAuth client secrets are created by hand in the console (see 05-oauth.md).
# Placeholders so Cloud Run can reference them before they are filled in.
put warmbly-box-google-client-id     "PLACEHOLDER"
put warmbly-box-google-client-secret "PLACEHOLDER"
put warmbly-google-client-id         "PLACEHOLDER"
put warmbly-google-client-secret     "PLACEHOLDER"

echo
echo "BACK THESE UP OUTSIDE GCP NOW (password manager):"
echo "  warmbly-credentials-encryption-key"
echo "  warmbly-kms-local-master-key"
echo "Losing either makes every connected mailbox permanently unrecoverable."
echo "  ./dump-keys.sh   # prints them for copying"

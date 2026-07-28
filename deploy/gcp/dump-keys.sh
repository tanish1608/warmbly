#!/usr/bin/env bash
# Print the two unrecoverable keys so you can paste them into a password manager.
# Nothing is written to disk.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

for s in warmbly-credentials-encryption-key warmbly-kms-local-master-key; do
  printf '%-38s %s\n' "$s" "$(gc secrets versions access latest --secret="$s")"
done

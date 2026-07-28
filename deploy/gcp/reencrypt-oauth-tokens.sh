#!/usr/bin/env bash
# One-off repair: seal OAuth tokens that were written in plaintext by the
# pre-fix build (the INSERT stored them raw while the SELECT decrypts, so those
# rows fail to hex-decode and the mailbox can never send).
#
# Idempotent: a row whose token already decrypts is left alone, so re-running is
# safe. Delete this script once no deployment predates the fix.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

KEY="$(gc secrets versions access latest --secret=warmbly-credentials-encryption-key)"
DSN="$(gc secrets versions access latest --secret=warmbly-primary-db)"

# Runs on the infra VM: Cloud SQL has a private IP, so this box is the only
# place with both database reachability and the key.
gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap --command \
  "CRED_KEY='${KEY}' DB_DSN='${DSN}' bash -s" <<'REMOTE'
set -euo pipefail
sudo docker run --rm -i \
  -e CRED_KEY="$CRED_KEY" -e DB_DSN="$DB_DSN" \
  python:3.12-alpine sh -c '
pip install --quiet psycopg[binary] cryptography 2>/dev/null
python - <<PY
import os, binascii, psycopg
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

key = bytes.fromhex(os.environ["CRED_KEY"])
aes = AESGCM(key)

def looks_sealed(v: str) -> bool:
    # Decide by attempting the real decrypt, not by "is it hex": a plaintext
    # token could be accidentally hex-shaped, and re-sealing an already-sealed
    # row would double-encrypt it.
    try:
        raw = binascii.unhexlify(v)
    except Exception:
        return False
    if len(raw) < 12:
        return False
    try:
        aes.decrypt(raw[:12], raw[12:], None)
        return True
    except Exception:
        return False

def seal(plain: str) -> str:
    nonce = os.urandom(12)
    ct = aes.encrypt(nonce, plain.encode(), None)
    return nonce.hex() + ct.hex()

with psycopg.connect(os.environ["DB_DSN"]) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT email_account_id, access_token, refresh_token FROM email_accounts_oauth")
        rows = cur.fetchall()
        fixed = skipped = 0
        for acct, at, rt in rows:
            if looks_sealed(at) and looks_sealed(rt):
                skipped += 1
                continue
            cur.execute(
                "UPDATE email_accounts_oauth SET access_token=%s, refresh_token=%s WHERE email_account_id=%s",
                (seal(at), seal(rt), acct),
            )
            fixed += 1
        conn.commit()
print(f"sealed {fixed} row(s), already-sealed {skipped}")
PY
'
REMOTE

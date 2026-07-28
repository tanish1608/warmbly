#!/usr/bin/env bash
# Create the free and premium warmup pools.
#
# The migrations create warmup_pools but never populate it, and the only INSERTs
# live in the demo/sandbox seeds. On a real self-host the table stays empty, so
# EnsurePoolMembershipWithRole -> GetPoolByType returns nil and enabling warmup
# fails with "warmup pool not found". Mailboxes then show warmup as on while
# never joining a pool, so no warmup mail is ever exchanged.
#
# Keep both pools: free and premium traffic must stay separated (see CLAUDE.md).
# Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

DSN="$(gc secrets versions access latest --secret=warmbly-primary-db)"

gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap --command \
  "DB_DSN='${DSN}' bash -s" <<'REMOTE'
set -euo pipefail
sudo docker run --rm -i -e DB_DSN="$DB_DSN" \
  postgres:16-alpine psql "$DB_DSN" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO warmup_pools (id, pool_type, name, description, max_participants) VALUES
  ('77777777-aaaa-0000-0000-000000000001','free'::warmup_pool_type,   'Free warmup pool',    'Self-host default pool', 1000),
  ('77777777-aaaa-0000-0000-000000000002','premium'::warmup_pool_type,'Premium warmup pool', 'Self-host default pool', 1000)
ON CONFLICT (id) DO NOTHING;

SELECT pool_type, name, max_participants FROM warmup_pools ORDER BY pool_type;
SQL
REMOTE

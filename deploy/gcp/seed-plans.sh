#!/usr/bin/env bash
# Seed the plan catalogue and give every organization a subscription.
#
# A fresh self-host has an empty `plans` table, so the trial subscription that
# registration tries to create fails its plan_id foreign key and the org ends up
# with none. GET /v1/subscription then 404s, and the dashboard treats the
# undefined response as "no entitlements": the unified inbox looks locked, the
# plan reads "Starter", and warmup-config screens crash on `.map()` of undefined.
#
# Deliberately does NOT set stripe_subscription_id. Subscription.HasPaidSubscription()
# keys off that column, and a non-null value flips AssignWorkerToEmail to look for a
# PREMIUM worker while this deployment runs a single shared_free one, silently
# unassigning every mailbox. Server-side entitlements come from BILLING_PROVIDER=none
# (feature.gate selfHost) regardless, so this only fixes what the UI reads.
#
# Idempotent. Safe to re-run; it never touches the demo fixtures in cmd/seed.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

DSN="$(gc secrets versions access latest --secret=warmbly-primary-db)"

# Enterprise: the only plan whose caps are nil/large enough not to fight a
# self-host that has no billing at all.
PLAN_ID="00000000-0000-0000-0000-000000000130"

gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap --command \
  "DB_DSN='${DSN}' PLAN_ID='${PLAN_ID}' bash -s" <<'REMOTE'
set -euo pipefail
sudo docker run --rm -i -e DB_DSN="$DB_DSN" -e PLAN_ID="$PLAN_ID" \
  postgres:16-alpine psql "$DB_DSN" -v ON_ERROR_STOP=1 -v plan="$PLAN_ID" <<'SQL'
INSERT INTO durations (id, title) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'Monthly'),
  ('00000000-0000-0000-0000-0000000000d2', 'Yearly')
ON CONFLICT (id) DO NOTHING;

INSERT INTO plans (
  id, name, max_contacts, daily_emails, ai_generation, account_limit,
  price, discounted_price, duration_id, savings, public,
  dedicated_workers, daily_campaign_limit,
  max_campaigns, max_active_campaigns, max_team_members, max_email_accounts,
  monthly_credits
) VALUES
  ('00000000-0000-0000-0000-000000000001','Free Trial',100,20,false,2,0,0,'00000000-0000-0000-0000-0000000000d1',0,false,0,20,2,1,1,2,50),
  ('00000000-0000-0000-0000-000000000110','Starter',1000,100,false,3,29,29,'00000000-0000-0000-0000-0000000000d1',0,true,0,100,5,2,2,3,250),
  ('00000000-0000-0000-0000-000000000120','Pro',25000,1000,true,20,99,99,'00000000-0000-0000-0000-0000000000d1',0,true,1,1000,50,20,10,20,2000),
  ('00000000-0000-0000-0000-000000000130','Enterprise',1000000,10000,true,500,0,0,'00000000-0000-0000-0000-0000000000d1',0,false,3,10000,NULL,NULL,NULL,NULL,25000)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  max_contacts = EXCLUDED.max_contacts,
  daily_emails = EXCLUDED.daily_emails,
  ai_generation = EXCLUDED.ai_generation,
  account_limit = EXCLUDED.account_limit,
  max_email_accounts = EXCLUDED.max_email_accounts,
  max_campaigns = EXCLUDED.max_campaigns,
  max_active_campaigns = EXCLUDED.max_active_campaigns,
  max_team_members = EXCLUDED.max_team_members,
  daily_campaign_limit = EXCLUDED.daily_campaign_limit,
  monthly_credits = EXCLUDED.monthly_credits,
  updated_at = NOW();

-- One active subscription per org, owned by whoever created it.
INSERT INTO subscriptions (id, user_id, organization_id, plan_id, stripe_customer_id, status)
SELECT gen_random_uuid(), o.owner_user_id, o.id, :'plan'::uuid, '', 'active'
FROM organizations o
WHERE NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.organization_id = o.id);

UPDATE subscriptions SET plan_id = :'plan'::uuid, status = 'active', updated_at = NOW()
WHERE stripe_subscription_id IS NULL;

SELECT o.name AS org, p.name AS plan, s.status
FROM subscriptions s
JOIN organizations o ON o.id = s.organization_id
JOIN plans p ON p.id = s.plan_id;
SQL
REMOTE

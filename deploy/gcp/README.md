# Warmbly on Google Cloud — operations guide

Single-tenant self-host of a forked [Warmbly](https://github.com/warmbly/warmbly)
in GCP project **`warmbly-503807`** (project number `390860474553`), region
**`us-central1`**.

Every script here is idempotent. Re-running one is always safe.

---

## 1. Live URLs

| Service | URL |
|---|---|
| **Dashboard** | https://warmbly-web-390860474553.us-central1.run.app |
| **Admin** | https://warmbly-admin-390860474553.us-central1.run.app |
| **API** | https://warmbly-backend-390860474553.us-central1.run.app |
| Tracking (open/click) | https://warmbly-tracking-390860474553.us-central1.run.app |
| Realtime (websocket) | https://warmbly-realtime-390860474553.us-central1.run.app |

Cloud Run also serves an equivalent `-haftwyx5dq-uc.a.run.app` form of each. Both
work; the project-number form is the one registered as an OAuth redirect URI, but
its DNS can lag a few minutes behind a **newly created** service.

Login is email + password. "Sign in with Google" is broken upstream (see §9).

---

## 2. Architecture

```
                    Cloud Run (us-central1)
  web ──┐
 admin ─┼─► backend ◄── tracking          Direct VPC egress
        │      │  ▲                              │
   realtime ◄──┘  └────────────┐                 ▼
                               │      ┌──────────────────────┐
                               └─────►│ warmbly-worker VM    │
                                      │  redis    :6379      │
   Cloud SQL (private IP) ◄───────────│  nats     :4222      │
   warmbly-pg  10.124.0.3             │  mailpit  :1025/8025 │
                                      │  consumer            │
                                      │  worker              │
                                      └──────────────────────┘
```

**Five Cloud Run services, not six.** `cmd/consumer` never opens an HTTP
listener, so Cloud Run's startup probe can never pass. It runs on the VM.

**One worker is deliberate.** The worker-per-IP fleet upstream exists to spread
SMTP across many IPs. Gmail API sending leaves from Google's IPs, so our own IP
reputation is irrelevant. Add workers only if you connect generic SMTP mailboxes.

Nothing but the five HTTPS front doors is public. Postgres is private-IP only;
Redis/NATS/Mailpit are reachable solely from the Cloud Run subnet via a firewall
rule scoped to the `warmbly-infra` tag.

---

## 3. First-time deploy, in order

```bash
cd deploy/gcp
./01-secrets.sh        # generate + store every secret (run once)
./dump-keys.sh         # BACK UP the two unrecoverable keys, immediately
./02-infra.sh          # service accounts, Artifact Registry, VPC peering, Cloud SQL (~10 min)
./03-guardrails.sh     # $100/mo budget, alerts at 50/90/100% + forecast
./06-infra-vm.sh       # the VM: redis + nats + mailpit via cloud-init
./04-build.sh          # build all 7 images -> Artifact Registry (~13 min)
./07-deploy-run.sh     # deploy the 5 Cloud Run services
./08-vm-services.sh    # install consumer + worker on the VM
./seed-plans.sh        # plan catalogue + an active subscription per org
./seed-warmup-pools.sh # the free and premium warmup pools
./verify.sh            # smoke-check everything
# then follow 05-oauth.md — the only manual step
```

`05-oauth.md` is manual because Google does not expose OAuth client creation via
`gcloud`. Everything else is scripted.

### Day-to-day

```bash
./04-build.sh backend web     # rebuild ONLY these (~1m40s vs ~13m for all seven)
./07-deploy-run.sh            # redeploy Cloud Run (skips services whose tag wasn't built)
./08-vm-services.sh           # restart consumer + worker with the newest image
./verify.sh                   # confirm everything is healthy
```

Always name the services you changed. A full rebuild is dominated by the Rust
tracking image, which alone takes 10–13 minutes.

---

## 4. Resetting the mailbox limits

Two separate limits exist. The one that bit us is the **daily** one.

### The 5-per-day cap (this is the "6 account limit")

`DailyThrottleNewMailboxes = 5` in `internal/config/constants.go:106` — five newly
connected mailboxes per org per day. Failed connection attempts **also count**, so
a few retries exhaust it and you get `429` on `/emails/onboarding/oauth/finish`.

**Permanent fix** (do this before building a mailbox fleet):

```go
// internal/config/constants.go
DailyThrottleNewMailboxes = 50   // was 5
```

then `./04-build.sh backend && ./07-deploy-run.sh`.

**One-off reset** (unblocks you today, resets at UTC midnight anyway):

```bash
ORG=3393cd46-3ca4-444b-85b7-ab1528aac7b1
gcloud compute ssh warmbly-worker --zone us-central1-a --project warmbly-503807 \
  --command "sudo docker exec redis redis-cli DEL 'dailythrottle:mailbox:${ORG}:$(date -u +%F)'"
```

Key format is `dailythrottle:<resource>:<org-uuid>:<YYYY-MM-DD>` (UTC). Other
resources use the same shape: `campaign` (20/day), `org` (3/day).

Prefer raising the constant over deleting Redis keys — reaching into the
datastore to unblock the app is not a habit worth forming.

### The per-plan cap

`plans.max_email_accounts` bounds the total. Your org is on **Enterprise**, where
it is `NULL` (unlimited), so this one is already handled. `./seed-plans.sh` sets
it; re-run it if the plan ever changes.

---

## 5. Common operations

**Read logs**

```bash
gcloud run services logs read warmbly-backend --region us-central1 --project warmbly-503807 --limit 50
gcloud compute ssh warmbly-worker --zone us-central1-a --project warmbly-503807 \
  --command 'sudo journalctl -u warmbly-worker -f'      # or warmbly-consumer
```

**Read platform mail** (signup confirmations, password resets, invites) — Mailpit
is not public, so tunnel to it:

```bash
gcloud compute ssh warmbly-worker --zone us-central1-a --project warmbly-503807 -- -L 8025:localhost:8025 -N
# then open http://localhost:8025
```

**Query the database** — Cloud SQL is private-IP, so go through the VM:

```bash
gcloud compute ssh warmbly-worker --zone us-central1-a --project warmbly-503807 --command \
  'DSN=$(sudo grep "^PRIMARY_DB=" /var/lib/warmbly/secrets.env | cut -d= -f2-); \
   sudo docker run --rm postgres:16-alpine psql "$DSN" -c "select email, status from email_accounts;"'
```

**Rotate a secret**

```bash
printf '%s' "$NEW" | gcloud secrets versions add warmbly-<name> --data-file=- --project warmbly-503807
./07-deploy-run.sh && ./08-vm-services.sh
```

Never rotate `warmbly-credentials-encryption-key` or `warmbly-kms-local-master-key`.
Both seal stored mailbox credentials; rotating either makes every connected
mailbox permanently unrecoverable.

**Update OAuth client credentials**

```bash
./set-oauth-secret.sh box-google '<client-id>' '<client-secret>'   # mailbox client
./07-deploy-run.sh && ./08-vm-services.sh
```

---

## 6. Configuration that is easy to get wrong

**`WORKER_TIER=shared_free`, not `shared`.** `BILLING_PROVIDER=none` means no
Stripe subscription id, so `Subscription.HasPaidSubscription()` is false and
`AssignWorkerToEmail` looks for a *free-tier* worker. Any other value registers
the worker as shared_premium and mailboxes sit unassigned forever, with nothing
in the logs to explain it. Set in `08-vm-services.sh`.

**Never set `subscriptions.stripe_subscription_id`.** Same mechanism in reverse:
a non-null value flips the org to "paid", assignment starts looking for a premium
worker, and every mailbox silently unassigns. `seed-plans.sh` deliberately leaves
it null — entitlements come from `BILLING_PROVIDER=none`, not from the plan row.

**`PUBLIC_API_URL` is separate from `API_HOST`.** Upstream used `API_HOST` as both
the listen address and the OAuth redirect base. On Cloud Run those differ, so
redirect URIs came out as `0.0.0.0:8080/addresses/google/callback`. This fork adds
`PUBLIC_API_URL`, falling back to `API_HOST` when unset.

**The event bus is NATS, not Pub/Sub.** `EVENTBUS_PROVIDER` accepts only `kafka`
or `nats`. `PUBSUB_ENABLED` is a different, narrower switch selecting the realtime
fanout transport. We run `PUBSUB_ENABLED=false` (Redis bridge) with NATS JetStream
on the VM.

**Blobs go to GCS, not the filesystem.** Cloud Run's disk is ephemeral, so
`BLOB_PROVIDER=filesystem` would drop uploaded avatars/logos on every restart.

**backend and realtime run `--no-cpu-throttling` at min=max=1.** Cloud Run only
allocates CPU during requests by default, which would freeze the campaign and
warmup schedulers between HTTP calls. A single instance also keeps the schedulers
singleton. `tracking`, `web` and `admin` scale to zero.

**`WARMBLY_TURNSTILE_KEY` must be set on web/admin** even with
`CAPTCHA_PROVIDER=none`. The dashboard always renders the widget and an empty
sitekey hangs it on "Verification timed out", blocking signup entirely.
Cloudflare's always-passing test key `1x00000000000000000000AA` is correct here.

**`SMTP_HOST` must point somewhere.** Unset, the mailer falls back to AWS SES and
every registration 500s on a DNS lookup for `email.<region>.amazonaws.com`.

**`GEODB_PATH` must be set** and is read with the required `GetString`. GeoLite2
is a licensed MaxMind download no image ships; this fork makes an absent file
non-fatal.

---

## 7. Build and deploy gotchas

- Cloud Build steps need `env: ["DOCKER_BUILDKIT=1"]` — the Dockerfiles use
  `# syntax=` directives and cache mounts the classic builder cannot parse.
- `gcloud run deploy --set-env-vars` treats commas as the pair separator, so
  `CORS_ALLOW_ORIGINS` needs `--env-vars-file` YAML. Escaping does not help.
- `PORT` is a reserved Cloud Run env name; passing it explicitly is rejected.
- Container-Optimized OS mounts `/var` **noexec** with a **read-only root**.
  systemd units invoke helpers as `/bin/bash /path/script.sh` and set
  `Environment=HOME=/var/lib/warmbly` so `docker-credential-gcr` can write.
- `pnpm build` in `web/` is `vite build` with **no** `tsc` — a Docker image build
  is not a typecheck. Run `tsc -b` separately.
- Cloud SQL `db-g1-small` requires `--edition=ENTERPRISE`.
- Building all seven images locally on an 8GB Mac OOM-kills the Go compiler
  (Docker Desktop caps at ~3.8GB). Build one service at a time, or use Cloud Build.

---

## 8. Fixes carried in this fork

Upstream bugs found while deploying. All are in `deploy/gcp`-adjacent code and
would make good upstream PRs.

| Fix | Why |
|---|---|
| Seal OAuth tokens at rest | `NewOauthAccount`/`RefreshBoxToken` stored access + refresh tokens **raw** while `GetOauthCredentials` decrypts on read. Gmail refresh tokens sat in plaintext **and** every credential read failed, so an OAuth mailbox could never send. |
| OAuth popup origin | The dashboard only trusted `APP_URL`, but the callback popup is served by the **API**. Any split-origin deployment dropped every message and the connect silently never finished — true on Cloud Run and in upstream's own docker-compose. |
| `APP_ORIGIN` default | Was unset, so the backend `postMessage`d the OAuth code with target `*`, broadcasting it to whatever origin owned the opener. |
| `PUBLIC_API_URL` | Split from the overloaded `API_HOST` so OAuth redirects work behind a proxy. |
| Missing GeoIP non-fatal | Backend `log.Fatal`ed outside dev on a licensed file no image ships. |
| Tracking bus retry | `async_nats::connect`'s 5s timeout raced Cloud Run's VPC interface setup; the service crash-looped. Now retries with backoff. |
| GCP KMS provider | `internal/infrastructure/kms/gcp.go`, `KMS_PROVIDER=gcp`. Not adopted here — switching providers needs a DEK migration, so this deployment stays on `local` + Secret Manager. |
| `seed-plans.sh` | A fresh self-host has an empty `plans` table, so registration's trial subscription fails its FK and `/v1/subscription` 404s. The dashboard then reads no entitlements: locked inbox, "Starter" label, `.map()` of undefined. |
| `seed-warmup-pools.sh` | Migrations declare `warmup_pools` but never populate it; only demo seeds insert rows. `GetPoolByType` returned nil, so enabling warmup failed with "warmup pool not found" while the mailbox still showed warmup as on. |

---

## 9. Known-broken, not fixed

- **"Sign in with Google"** — `web/src/components/auth/external.tsx:116` opens
  `${API_URL}/auth/google/login`, which is not a route. The only Google login
  route is `POST /v1/auth/google`, expecting an ID token from the JS SDK. The
  button 404s for everyone. Email+password and passkeys work; mailbox OAuth is
  unaffected.
- Console noise: `Cannot read properties of undefined (reading 'contains')`, a
  Turnstile `size: "invisible"` warning, and `[WS] Cannot push to channel`. All
  upstream frontend, all harmless.

---

## 10. Cost

| Item | Monthly |
|---|---|
| Cloud Run: backend + realtime, always-on 1 vCPU | $25–40 |
| Cloud Run: tracking + web + admin, scale to zero | $0–5 |
| Cloud SQL `db-g1-small` ENTERPRISE, 20GB, 7 backups | $25–35 |
| `e2-medium` VM (redis + nats + mailpit + consumer + worker) | ~$27 |
| Artifact Registry, Secret Manager, GCS, egress | <$5 |
| **Total** | **~$80–110** |

Budget alerts fire at 50/90/100% of $100 plus a forecast trigger. Cloud Run
max-instances are capped per service in `07-deploy-run.sh`.

Higher than the original plan's "$55 lean" estimate because always-allocated CPU
on the two scheduler-bearing services is the real cost of running them on Cloud
Run. Moving the backend to the VM would save ~$20/mo at the cost of managed TLS,
rollouts and autoscaling — not worth it.

---

## 11. Current state and what is left

**Working:** all five Cloud Run services healthy · Cloud SQL with migrations
applied · redis/nats/mailpit/consumer/worker active on the VM · 7 Gmail mailboxes
connected, tokens sealed, all assigned to the worker · warmup pools created ·
org on an active Enterprise subscription.

**Blocked — Google side, not Warmbly:** the connected accounts return
*"you do not have access to Gmail"*. The Gmail **service** is disabled for those
Workspace users, or the accounts are on Cloud Identity Free (which excludes Gmail
entirely). Fix in `admin.google.com`:

1. **Billing → Subscriptions** — confirm a real Google Workspace licence, not
   Cloud Identity Free
2. **Apps → Google Workspace → Gmail → Service status → ON**
3. Confirm **MX records** point at Google and the domain is verified

No mail moves until this is done.

**Then, before treating warmup as real:**

- Lower the ramp. Mailboxes are currently at `warmup_base` 20–50/day with max
  100. Repo defaults are **10/day start, 40/day ceiling**. Starting a fresh
  mailbox at 40–50/day is how mailboxes get flagged.
- Fix the pool. All 7 mailboxes are Gmail on 3 domains, so
  `CountEligibleRecipients` caps each to ~6 sends/day, and Gmail-to-Gmail inside
  one org may never traverse spam filtering at all. Add **receive-only**
  participants on Outlook / Yahoo / Proton (`recipient_only` role) — free, and
  the highest leverage per dollar. Target ~20 mailboxes across ≥4 providers and
  ≥3 domains.
- Verify **follow-up threading** and **reply detection** on a real send. Both are
  silent breakers and neither can be tested until Gmail works.
- Turn **open tracking off** before real campaigns — it is a spam signal and the
  data is not worth the deliverability cost.

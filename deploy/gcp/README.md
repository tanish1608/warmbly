# Warmbly on Google Cloud

Single-tenant deployment for `warmbly-503807` in `us-central1`. Five Cloud Run
services for the control plane, one VM carrying Redis, NATS, the consumer and
the worker.

Every script is idempotent. Re-running one is always safe.

## Shape

```
                    Cloud Run (us-central1)
  web ──┐
 admin ─┼─► backend ◄── tracking          Direct VPC egress
        │      │  ▲                              │
   realtime ◄──┘  └────────────┐                 ▼
                               │      ┌──────────────────────┐
                               └─────►│ warmbly-worker VM    │
                                      │  redis :6379         │
   Cloud SQL (private IP) ◄───────────│  nats  :4222         │
   10.124.0.3                         │  consumer            │
                                      │  worker              │
                                      └──────────────────────┘
```

Five Cloud Run services, not six. The consumer is on the VM because
`cmd/consumer` never opens an HTTP listener (it only subscribes to the event
bus), so Cloud Run's startup probe can never pass.

One worker is deliberate. The worker-per-IP fleet in the upstream architecture
exists to spread SMTP across many IPs. Gmail API sending leaves from Google's
IPs, so our own IP reputation does not matter. Add workers only when generic
SMTP mailboxes get connected.

## Order

```bash
cd deploy/gcp
./01-secrets.sh      # generate + store every secret. Run once, then back up.
./dump-keys.sh       # copy the two unrecoverable keys to a password manager NOW
./02-infra.sh        # service accounts, Artifact Registry, VPC peering, Cloud SQL (~10 min)
./03-guardrails.sh   # $100/mo budget with 50/90/100% + forecast alerts
./06-infra-vm.sh     # the VM, with Redis + NATS via cloud-init
./04-build.sh        # Cloud Build all seven images -> Artifact Registry
./07-deploy-run.sh   # deploy the five Cloud Run services
./08-vm-services.sh  # install consumer + worker on the VM
# then: 05-oauth.md  # the only manual step, ~15 minutes in the console
```

`05-oauth.md` is manual because Google does not expose OAuth client creation
through `gcloud`. Everything else is scripted.

## Things that are not obvious

**`WORKER_TIER=shared_free`, not `shared`.** `BILLING_PROVIDER=none` means no
Stripe subscription id, so `Subscription.HasPaidSubscription()` is false and
`AssignWorkerToEmail` looks for a free-tier worker. Any other `WORKER_TIER`
value registers the worker as shared_premium, and mailboxes would sit
unassigned forever with no error to explain it. Set in `08-vm-services.sh`.

**`PUBLIC_API_URL` is separate from `API_HOST`.** Upstream used `API_HOST` both
as the listen address and as the OAuth redirect base. On Cloud Run the listen
address is `0.0.0.0:8080` and the public URL is the `run.app` hostname, so OAuth
redirect URIs came out as `0.0.0.0:8080/addresses/google/callback`. This fork
adds `PUBLIC_API_URL` (see `internal/config/config_api.go`), falling back to
`API_HOST` when unset so existing deployments are unaffected.

**The event bus is NATS, not Pub/Sub.** `EVENTBUS_PROVIDER` accepts only `kafka`
or `nats`. `PUBSUB_ENABLED` is a different, narrower switch: it selects the
transport for realtime fanout from backend/consumer to the Elixir service. We
run `PUBSUB_ENABLED=false` (Redis bridge) and NATS JetStream on the VM.

**Blobs go to GCS, not the filesystem.** Cloud Run's filesystem is ephemeral, so
`BLOB_PROVIDER=filesystem` would drop uploaded avatars/logos on every restart.
`07-deploy-run.sh` creates a bucket plus an HMAC key and uses the S3-compatible
provider against `storage.googleapis.com`.

**backend and realtime run `--no-cpu-throttling` at min=max=1.** Cloud Run
only allocates CPU during requests by default, which would freeze the campaign
and warmup schedulers between HTTP calls. They run as in-process goroutines, so
CPU has to stay allocated, and a single instance keeps the schedulers singleton.
`tracking`, `web` and `admin` scale to zero.

**`GEODB_PATH` is required and must point somewhere.** It is read with the
required `GetString`, and upstream `cmd/backend/main.go` only tolerated an
unopenable database when `APP_ENV=dev`. GeoLite2 is a licensed MaxMind download
that no image ships, so a production self-host crash-looped before listening.
This fork treats a missing file as non-fatal everywhere (geo lookup is optional
enrichment) and still hard-fails outside dev on a corrupt one.

**Cloud Build needs `DOCKER_BUILDKIT=1`.** Every Dockerfile carries a
`# syntax=` directive and BuildKit cache mounts, which the classic builder in
`gcr.io/cloud-builders/docker` cannot parse.

## Rotating a secret

```bash
printf '%s' "$NEW" | gcloud secrets versions add warmbly-<name> --data-file=- --project warmbly-503807
./07-deploy-run.sh    # Cloud Run picks up :latest on the next revision
gcloud compute ssh warmbly-worker --zone us-central1-a --project warmbly-503807 \
  --command 'sudo systemctl restart warmbly-worker'
```

Never rotate `warmbly-credentials-encryption-key` or
`warmbly-kms-local-master-key`. Both seal stored mailbox credentials, and
rotating either makes every connected mailbox unrecoverable.

## Cost

| Item | Monthly |
|---|---|
| Cloud Run: backend + realtime, always-on 1 vCPU | $25-40 |
| Cloud Run: tracking + web + admin, scale to zero | $0-5 |
| Cloud SQL `db-g1-small` ENTERPRISE, 20GB, 7 backups | $25-35 |
| `e2-medium` VM (Redis + NATS + consumer + worker) | ~$27 |
| Artifact Registry, Secret Manager, GCS, egress | <$5 |
| **Total** | **~$80-110** |

Higher than the plan's "$55 lean" because always-allocated CPU on the two
scheduler-bearing Cloud Run services is the real cost of running them there.
Moving the backend onto the VM as well would cut roughly $20/mo at the cost of
managed rollouts and autoscaling.

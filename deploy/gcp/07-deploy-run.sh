#!/usr/bin/env bash
# Deploy the five control-plane services to Cloud Run.
#
# All five sit in one region and reach Cloud SQL (private IP) and Redis/NATS (the
# infra VM) over Direct VPC egress, so nothing but the HTTPS front doors is
# public.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

TAG="${TAG:-$(cat .last-tag 2>/dev/null || echo latest)}"
PROJECT_NUMBER="$(gc projects describe "$PROJECT_ID" --format='value(projectNumber)')"
INFRA_IP="$(gc compute addresses describe warmbly-infra-ip --region="$REGION" --format='value(address)')"

url_for() { echo "https://warmbly-$1-${PROJECT_NUMBER}.${REGION}.run.app"; }
BACKEND_URL="$(url_for backend)"
WEB_URL="$(url_for web)"
ADMIN_URL="$(url_for admin)"
REALTIME_URL="$(url_for realtime)"
TRACKING_URL="$(url_for tracking)"
TRACKING_HOST="${TRACKING_URL#https://}"

echo "Deploying tag ${TAG}"
echo "  backend  ${BACKEND_URL}"
echo "  web      ${WEB_URL}"
echo

# ── one-time: blob storage on GCS over the S3-compatible API ──────────────
# Cloud Run's filesystem is ephemeral, so BLOB_PROVIDER=filesystem would drop
# every uploaded avatar/logo on each restart.
BUCKET="${PROJECT_ID}-warmbly-blobs"
gc storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1 \
  || gc storage buckets create "gs://${BUCKET}" --location="$REGION" --uniform-bucket-level-access
gc storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${RUN_SA}" --role=roles/storage.objectAdmin >/dev/null 2>&1 || true

if ! gc secrets describe warmbly-gcs-hmac-key >/dev/null 2>&1; then
  echo "== creating GCS HMAC key for the S3-compatible blob client =="
  HMAC_JSON="$(gc storage hmac create "$RUN_SA" --format=json)"
  printf '%s' "$(echo "$HMAC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["accessId"])')" \
    | gc secrets create warmbly-gcs-hmac-key --data-file=- --replication-policy=automatic >/dev/null
  printf '%s' "$(echo "$HMAC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')" \
    | gc secrets create warmbly-gcs-hmac-secret --data-file=- --replication-policy=automatic >/dev/null
fi

# ── connection strings, stored whole so the password never lands in env ──
SQL_IP="$(gc sql instances describe "$SQL_INSTANCE" --format='value(ipAddresses[0].ipAddress)')"
DB_PASS="$(gc secrets versions access latest --secret=warmbly-db-password)"
DSN="postgres://${SQL_USER}:${DB_PASS}@${SQL_IP}:5432/${SQL_DB}?sslmode=disable"
if [ "$(gc secrets versions access latest --secret=warmbly-primary-db 2>/dev/null || echo)" != "$DSN" ]; then
  gc secrets describe warmbly-primary-db >/dev/null 2>&1 \
    || gc secrets create warmbly-primary-db --replication-policy=automatic --data-file=/dev/null >/dev/null
  printf '%s' "$DSN" | gc secrets versions add warmbly-primary-db --data-file=- >/dev/null
fi

SEC() { echo "$1=warmbly-$2:latest"; }

# The dashboard always renders the Turnstile widget, and an empty sitekey makes
# it hang on "Verification timed out" so nobody can sign up or log in. The
# backend runs CAPTCHA_PROVIDER=none and never validates the token, so
# Cloudflare's always-passing test key is the correct value here. Override with
# a real sitekey only alongside CAPTCHA_PROVIDER=turnstile + TURNSTILE_SECRET.
TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-1x00000000000000000000AA}"

# Platform mail (signup confirmation, password reset, invites) goes to Mailpit on
# the infra VM. With SMTP_HOST unset the mailer falls back to AWS SES and every
# registration 500s on a DNS lookup for email.<region>.amazonaws.com. Point
# SMTP_HOST/SMTP_PORT at a real relay when this stops being a single-tenant box.

COMMON_SECRETS="$(SEC AUTH_SECRET auth-secret),$(SEC CREDENTIALS_ENCRYPTION_KEY credentials-encryption-key),$(SEC KMS_LOCAL_MASTER_KEY kms-local-master-key),$(SEC INTERNAL_API_TOKEN internal-api-token),$(SEC PRIMARY_DB primary-db),$(SEC AWS_ACCESS_KEY_ID gcs-hmac-key),$(SEC AWS_SECRET_ACCESS_KEY gcs-hmac-secret)"

VPC="--network=default --subnet=default --vpc-egress=private-ranges-only"

ENVDIR="$(mktemp -d)"
trap 'rm -rf "$ENVDIR"' EXIT

# Env goes through a YAML file rather than --set-env-vars: CORS_ALLOW_ORIGINS is
# a comma-separated list, and gcloud parses commas as the pair separator.
# `key: |-` blocks keep every value literal, commas included.
envfile() {
  local name="$1" out="${ENVDIR}/${1}.yaml"
  : > "$out"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s: |-\n  %s\n' "${line%%=*}" "${line#*=}" >> "$out"
  done
  echo "$out"
}

# Resolve the image per service. 04-build.sh can build a subset, so TAG may not
# exist for every service; fall back to :latest (which every build also pushes)
# rather than aborting the whole deploy on the first service that wasn't rebuilt.
image_for() {
  local name="$1"
  if gc artifacts docker images describe "${IMAGE_BASE}/${name}:${TAG}" >/dev/null 2>&1; then
    echo "${IMAGE_BASE}/${name}:${TAG}"
  else
    echo "${IMAGE_BASE}/${name}:latest"
  fi
}

deploy() {
  local name="$1" env_yaml="$2"; shift 2
  # shellcheck disable=SC2086
  gc run deploy "warmbly-${name}" \
    --image="$(image_for "$name")" \
    --region="$REGION" --platform=managed \
    --service-account="$RUN_SA" \
    $VPC \
    --allow-unauthenticated \
    --env-vars-file="$env_yaml" \
    "$@"
}

common_env() {
  cat <<EOF
APP_ENV=production
AWS_CONFIG_ENABLED=false
EVENTBUS_PROVIDER=nats
NATS_URL=nats://${INFRA_IP}:4222
CODEC_PROVIDER=json
KMS_PROVIDER=local
TASKS_PROVIDER=local
BILLING_PROVIDER=none
CAPTCHA_PROVIDER=none
PUBSUB_ENABLED=false
REDIS=redis://${INFRA_IP}:6379
BLOB_PROVIDER=s3
BLOB_BUCKET=${BUCKET}
AWS_ENDPOINT_URL_S3=https://storage.googleapis.com
AWS_REGION=us-central1
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
GCP_PROJECT_ID=${PROJECT_ID}
EOF
}

echo "== backend =="
# min=max=1: the campaign/warmup schedulers run as in-process goroutines, and
# --no-cpu-throttling is what keeps them ticking between HTTP requests.
deploy backend "$( { common_env; cat <<EOF
API_HOST=0.0.0.0:8080
PUBLIC_API_URL=${BACKEND_URL}
GIN_MODE=release
APP_URL=${WEB_URL}
CORS_ALLOW_ORIGINS=${WEB_URL},${ADMIN_URL}
WEBSOCKET_URL=wss://${REALTIME_URL#https://}/socket/websocket
ENCRYPTED_KEYS_PROVIDER=postgres
TRACKING_DOMAIN=${TRACKING_HOST}
BLOB_PUBLIC_BASE_URL=${BACKEND_URL}/public
EMAIL_NAME=Warmbly
EMAIL_ADDRESS=noreply@warmbly.local
SMTP_HOST=${INFRA_IP}
SMTP_PORT=1025
GEODB_PATH=/app/data/GeoLite2-City.mmdb
EOF
} | envfile backend )" \
  --port=8080 --cpu=1 --memory=1Gi --no-cpu-throttling \
  --min-instances=1 --max-instances=1 --timeout=600 \
  --set-secrets="${COMMON_SECRETS},$(SEC BOX_GOOGLE_CLIENT_ID box-google-client-id),$(SEC BOX_GOOGLE_CLIENT_SECRET box-google-client-secret),$(SEC GOOGLE_CLIENT_ID google-client-id),$(SEC GOOGLE_CLIENT_SECRET google-client-secret)"

# The consumer is NOT here on purpose. cmd/consumer never opens an HTTP
# listener (it only subscribes to the event bus), so Cloud Run's startup probe
# can never pass. It runs on the VM instead: see 08-vm-services.sh.

echo "== realtime =="
# Websocket fanout: long-lived connections, so one always-on instance.
# PORT is deliberately absent: Cloud Run reserves it and injects it from
# --port, and passing it explicitly is rejected.
deploy realtime "$(cat <<EOF | envfile realtime
PHX_HOST=${REALTIME_URL#https://}
PUBSUB_ENABLED=false
CHECK_ORIGIN=false
REDIS_URL=redis://${INFRA_IP}:6379
DATABASE_SSL=false
EOF
)" \
  --port=4000 --cpu=1 --memory=512Mi --no-cpu-throttling \
  --min-instances=1 --max-instances=1 --timeout=3600 \
  --set-secrets="JWT_SECRET=warmbly-auth-secret:latest,SECRET_KEY_BASE=warmbly-secret-key-base:latest,DATABASE_URL=warmbly-primary-db:latest"

echo "== web =="
deploy web "$(cat <<EOF | envfile web
WARMBLY_API_URL=${BACKEND_URL}
WARMBLY_APP_URL=${WEB_URL}
WARMBLY_TRACKING_DOMAIN=${TRACKING_HOST}
WARMBLY_TURNSTILE_KEY=${TURNSTILE_SITE_KEY}
EOF
)" \
  --port=80 --cpu=1 --memory=256Mi --min-instances=0 --max-instances=3

echo "== admin =="
deploy admin "$(cat <<EOF | envfile admin
WARMBLY_API_URL=${BACKEND_URL}
WARMBLY_DASHBOARD_URL=${WEB_URL}
WARMBLY_ENV_LABEL=production
WARMBLY_TURNSTILE_KEY=${TURNSTILE_SITE_KEY}
EOF
)" \
  --port=80 --cpu=1 --memory=256Mi --min-instances=0 --max-instances=3

echo "== tracking =="
# Scales to zero: pure request/response, no background work.
deploy tracking "$(cat <<EOF | envfile tracking
TRACKING_HOST=0.0.0.0
TRACKING_PORT=3000
TRACKING_RATE_LIMIT_PER_MIN=300
EVENTBUS_PROVIDER=nats
NATS_URL=nats://${INFRA_IP}:4222
CODEC_PROVIDER=json
BACKEND_INTERNAL_URL=${BACKEND_URL}
EOF
)" \
  --port=3000 --cpu=1 --memory=512Mi \
  --min-instances=0 --max-instances=3 \
  --set-secrets="$(SEC INTERNAL_API_TOKEN internal-api-token)"

echo
echo "Dashboard ${WEB_URL}"
echo "Admin     ${ADMIN_URL}"
echo "API       ${BACKEND_URL}"
echo
echo "Migrations run on backend boot. Confirm:"
echo "  gcloud run services logs read warmbly-backend --region ${REGION} --project ${PROJECT_ID} --limit 50"

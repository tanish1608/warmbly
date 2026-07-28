#!/usr/bin/env bash
# Install the two long-running Go services on the infra VM: the consumer and the
# worker. Both sit alongside Redis and NATS.
#
# The consumer lives here rather than on Cloud Run because cmd/consumer never
# opens an HTTP listener; it only subscribes to the event bus, so Cloud Run's
# startup probe can never pass.
#
# Secrets are never written into instance metadata or copied over SSH: each unit
# fetches them at start from Secret Manager using the VM's own service account
# token, so rotating a secret is a `systemctl restart` away.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

TAG="${TAG:-$(cat .last-tag 2>/dev/null || echo latest)}"
PROJECT_NUMBER="$(gc projects describe "$PROJECT_ID" --format='value(projectNumber)')"
BACKEND_URL="https://warmbly-backend-${PROJECT_NUMBER}.${REGION}.run.app"
REALTIME_HOST="warmbly-realtime-${PROJECT_NUMBER}.${REGION}.run.app"
TRACKING_HOST="warmbly-tracking-${PROJECT_NUMBER}.${REGION}.run.app"
WEB_URL="https://warmbly-web-${PROJECT_NUMBER}.${REGION}.run.app"
BUCKET="${PROJECT_ID}-warmbly-blobs"
EXTERNAL_IP="$(gc compute instances describe "$WORKER_VM" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
SQL_IP="$(gc sql instances describe "$SQL_INSTANCE" --format='value(ipAddresses[0].ipAddress)')"

# Stable worker identity. Reputation is tracked per worker id, so it must
# survive reinstalls; derived once and kept in instance metadata.
WORKER_UUID="$(gc compute instances describe "$WORKER_VM" --zone="$ZONE" \
  --format='value(metadata.items.filter("key:warmbly-worker-id").extract("value"))' | tr -d "[]'")"
if [ -z "$WORKER_UUID" ]; then
  WORKER_UUID="$(python3 -c "import uuid;print(uuid.uuid5(uuid.NAMESPACE_DNS,'${WORKER_VM}.${PROJECT_ID}'))")"
  gc compute instances add-metadata "$WORKER_VM" --zone="$ZONE" \
    --metadata="warmbly-worker-id=${WORKER_UUID}" >/dev/null
fi
echo "Worker ID: ${WORKER_UUID}"

REMOTE="$(mktemp)"
trap 'rm -f "$REMOTE"' EXIT

cat > "$REMOTE" <<REMOTE_EOF
set -euo pipefail
sudo mkdir -p /var/lib/warmbly/bin

# Pull secrets from Secret Manager with the instance's own token.
sudo tee /var/lib/warmbly/bin/fetch-env.sh >/dev/null <<'FETCH'
#!/bin/bash
set -euo pipefail
TOKEN=\$(curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
sec() {
  curl -s -H "Authorization: Bearer \$TOKEN" \
    "https://secretmanager.googleapis.com/v1/projects/PROJECT_SUB/secrets/\$1/versions/latest:access" \
    | sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d
}
{
  echo "KMS_LOCAL_MASTER_KEY=\$(sec warmbly-kms-local-master-key)"
  echo "CREDENTIALS_ENCRYPTION_KEY=\$(sec warmbly-credentials-encryption-key)"
  echo "ENCRYPTED_KEYS_WORKER_TOKEN=\$(sec warmbly-internal-api-token)"
  echo "INTERNAL_API_TOKEN=\$(sec warmbly-internal-api-token)"
  echo "AUTH_SECRET=\$(sec warmbly-auth-secret)"
  echo "PRIMARY_DB=\$(sec warmbly-primary-db)"
  echo "AWS_ACCESS_KEY_ID=\$(sec warmbly-gcs-hmac-key)"
  echo "AWS_SECRET_ACCESS_KEY=\$(sec warmbly-gcs-hmac-secret)"
  echo "BOX_GOOGLE_CLIENT_ID=\$(sec warmbly-box-google-client-id)"
  echo "BOX_GOOGLE_CLIENT_SECRET=\$(sec warmbly-box-google-client-secret)"
} > /var/lib/warmbly/secrets.env
chmod 600 /var/lib/warmbly/secrets.env
FETCH
sudo sed -i "s/PROJECT_SUB/${PROJECT_ID}/" /var/lib/warmbly/bin/fetch-env.sh
# COS mounts /var noexec, so the units invoke this through bash rather than
# executing it directly. The +x is cosmetic but keeps manual runs obvious.
sudo chmod +x /var/lib/warmbly/bin/fetch-env.sh

# Shared, non-secret settings.
sudo tee /var/lib/warmbly/common.env >/dev/null <<'ENVCOMMON'
APP_ENV=production
AWS_CONFIG_ENABLED=false
EVENTBUS_PROVIDER=nats
NATS_URL=nats://localhost:4222
CODEC_PROVIDER=json
KMS_PROVIDER=local
REDIS=redis://localhost:6379
BLOB_PROVIDER=s3
AWS_ENDPOINT_URL_S3=https://storage.googleapis.com
AWS_REGION=auto
TASKS_PROVIDER=local
BILLING_PROVIDER=none
CAPTCHA_PROVIDER=none
PUBSUB_ENABLED=false
ENVCOMMON
echo "BLOB_BUCKET=${BUCKET}" | sudo tee -a /var/lib/warmbly/common.env >/dev/null
echo "GCP_PROJECT_ID=${PROJECT_ID}" | sudo tee -a /var/lib/warmbly/common.env >/dev/null

# WORKER_TIER=shared_free is deliberate, not a typo. BILLING_PROVIDER=none means
# no Stripe subscription id, so HasPaidSubscription() is false and
# AssignWorkerToEmail looks for a free-tier worker. A worker registered as
# shared_premium (what any other value maps to) would never receive a mailbox.
sudo tee /var/lib/warmbly/worker.env >/dev/null <<ENVWORKER
ENCRYPTED_KEYS_PROVIDER=http
ENCRYPTED_KEYS_BACKEND_URL=${BACKEND_URL}
WORKER_ID=${WORKER_UUID}
WORKER_TIER=shared_free
WORKER_EGRESS_KIND=cold_smtp
WORKER_PUBLIC_IP=${EXTERNAL_IP}
ENVWORKER

sudo tee /var/lib/warmbly/consumer.env >/dev/null <<ENVCONSUMER
ENCRYPTED_KEYS_PROVIDER=postgres
APP_URL=${WEB_URL}
WEBSOCKET_URL=wss://${REALTIME_HOST}/socket/websocket
TRACKING_DOMAIN=${TRACKING_HOST}
ENVCONSUMER

unit() {
  local svc="\$1" image="\$2" extra_env="\$3"
  sudo tee /etc/systemd/system/warmbly-\${svc}.service >/dev/null <<UNIT
[Unit]
Description=Warmbly \${svc}
After=docker.service redis.service nats.service
Requires=docker.service

[Service]
Restart=always
RestartSec=10
# COS has a read-only root, so docker-credential-gcr cannot create /root/.docker.
# Point HOME at the writable state dir; docker pull then reads the same config.
Environment=HOME=/var/lib/warmbly
ExecStartPre=/bin/bash /var/lib/warmbly/bin/fetch-env.sh
ExecStartPre=-/usr/bin/docker rm -f warmbly-\${svc}
ExecStartPre=/usr/bin/docker-credential-gcr configure-docker --registries ${REGION}-docker.pkg.dev
ExecStartPre=/usr/bin/docker pull \${image}
ExecStart=/usr/bin/docker run --rm --name warmbly-\${svc} \\
  --network host \\
  --env-file /var/lib/warmbly/common.env \\
  --env-file \${extra_env} \\
  --env-file /var/lib/warmbly/secrets.env \\
  \${image}
ExecStop=/usr/bin/docker stop warmbly-\${svc}

[Install]
WantedBy=multi-user.target
UNIT
}

unit consumer "${IMAGE_BASE}/consumer:${TAG}" /var/lib/warmbly/consumer.env
unit worker   "${IMAGE_BASE}/worker:${TAG}"   /var/lib/warmbly/worker.env

sudo systemctl daemon-reload
sudo systemctl enable warmbly-consumer.service warmbly-worker.service
sudo systemctl restart warmbly-consumer.service
sudo systemctl restart warmbly-worker.service
sleep 8
echo "--- status ---"
sudo systemctl is-active warmbly-consumer warmbly-worker || true
REMOTE_EOF

echo "== installing consumer + worker on ${WORKER_VM} =="
gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap --command="bash -s" < "$REMOTE"

echo
echo "Logs:"
echo "  gcloud compute ssh ${WORKER_VM} --zone ${ZONE} --project ${PROJECT_ID} --command 'sudo journalctl -u warmbly-worker -f'"
echo "  gcloud compute ssh ${WORKER_VM} --zone ${ZONE} --project ${PROJECT_ID} --command 'sudo journalctl -u warmbly-consumer -f'"
echo
echo "(Cloud SQL private IP for reference: ${SQL_IP})"

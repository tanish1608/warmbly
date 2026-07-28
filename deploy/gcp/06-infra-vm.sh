#!/usr/bin/env bash
# The single VM: Redis + NATS JetStream now, the Warmbly worker later (08).
#
# One worker is deliberate. The worker-per-IP fleet exists to spread SMTP across
# many IPs; Gmail API sending leaves from Google's IPs, so our own IP reputation
# is irrelevant. Add workers only if generic SMTP mailboxes get connected.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

echo "== static internal IP =="
gc compute addresses describe warmbly-infra-ip --region="$REGION" >/dev/null 2>&1 \
  || gc compute addresses create warmbly-infra-ip --region="$REGION" \
       --subnet=default --addresses=10.128.0.10 --purpose=GCE_ENDPOINT
INFRA_IP="$(gc compute addresses describe warmbly-infra-ip --region="$REGION" --format='value(address)')"

echo "== VM ${WORKER_VM} (${WORKER_MACHINE}) =="
if gc compute instances describe "$WORKER_VM" --zone="$ZONE" >/dev/null 2>&1; then
  echo "  = exists"
else
  gc compute instances create "$WORKER_VM" \
    --zone="$ZONE" --machine-type="$WORKER_MACHINE" \
    --image-family=cos-stable --image-project=cos-cloud \
    --boot-disk-size=30GB --boot-disk-type=pd-balanced \
    --private-network-ip="$INFRA_IP" \
    --tags=warmbly-infra \
    --service-account="$WORKER_SA" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata-from-file=user-data=cloud-init-infra.yaml
fi

echo
echo "Infra VM internal IP: ${INFRA_IP}"
echo "  REDIS     redis://${INFRA_IP}:6379"
echo "  NATS_URL  nats://${INFRA_IP}:4222"
echo
echo "Container-Optimized OS pulls and starts redis + nats on first boot; give it ~60s."

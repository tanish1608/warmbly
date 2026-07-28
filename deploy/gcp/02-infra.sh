#!/usr/bin/env bash
# Service accounts, Artifact Registry, private-IP Cloud SQL, and the firewall
# rules that let Cloud Run (Direct VPC egress) reach Redis + NATS on the infra VM.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

echo "== service accounts =="
for pair in "warmbly-run:Warmbly Cloud Run services" "warmbly-worker:Warmbly worker VM"; do
  name="${pair%%:*}"; desc="${pair#*:}"
  gc iam service-accounts describe "${name}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1 \
    || gc iam service-accounts create "$name" --display-name="$desc"
done

# Cloud Run services read secrets and talk to Cloud SQL. The worker reads only
# its own bootstrap secrets; it never opens a database connection (see CLAUDE.md).
for role in roles/secretmanager.secretAccessor roles/cloudsql.client roles/logging.logWriter; do
  gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUN_SA}" --role="$role" --condition=None >/dev/null
done
for role in roles/secretmanager.secretAccessor roles/logging.logWriter roles/monitoring.metricWriter roles/artifactregistry.reader; do
  gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WORKER_SA}" --role="$role" --condition=None >/dev/null
done
echo "  IAM bound"

echo "== artifact registry =="
gc artifacts repositories describe "$AR_REPO" --location="$REGION" >/dev/null 2>&1 \
  || gc artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" \
       --description="Warmbly service images"

echo "== private services access (for Cloud SQL private IP) =="
gc compute addresses describe warmbly-sql-range --global >/dev/null 2>&1 \
  || gc compute addresses create warmbly-sql-range \
       --global --purpose=VPC_PEERING --prefix-length=16 --network=default
gc services vpc-peerings list --network=default --format="value(peering)" 2>/dev/null | grep -q servicenetworking \
  || gc services vpc-peerings connect --service=servicenetworking.googleapis.com \
       --ranges=warmbly-sql-range --network=default

echo "== firewall =="
# Direct VPC egress from Cloud Run sources from the subnet range, so allow the
# whole default subnet to reach Redis/NATS on the infra VM. Nothing is public.
gc compute firewall-rules describe warmbly-allow-internal-infra >/dev/null 2>&1 \
  || gc compute firewall-rules create warmbly-allow-internal-infra \
       --network=default --direction=INGRESS --action=ALLOW \
       --rules=tcp:6379,tcp:4222 --source-ranges=10.128.0.0/9 \
       --target-tags=warmbly-infra \
       --description="Cloud Run -> Redis/NATS on the Warmbly infra VM"

echo "== cloud sql (this takes ~10 minutes) =="
if gc sql instances describe "$SQL_INSTANCE" >/dev/null 2>&1; then
  echo "  = ${SQL_INSTANCE} already exists"
else
  # ENTERPRISE (not the ENTERPRISE_PLUS default) is what allows shared-core tiers.
  gc sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_16 --edition=ENTERPRISE --tier="$SQL_TIER" --region="$REGION" \
    --network=default --no-assign-ip \
    --storage-size=20GB --storage-auto-increase \
    --backup --backup-start-time=07:00 --retained-backups-count=7 \
    --maintenance-window-day=SUN --maintenance-window-hour=8 \
    --database-flags=max_connections=200
fi

DB_PASS="$(gc secrets versions access latest --secret=warmbly-db-password)"
gc sql users list --instance="$SQL_INSTANCE" --format="value(name)" | grep -qx "$SQL_USER" \
  || gc sql users create "$SQL_USER" --instance="$SQL_INSTANCE" --password="$DB_PASS"
gc sql databases list --instance="$SQL_INSTANCE" --format="value(name)" | grep -qx "$SQL_DB" \
  || gc sql databases create "$SQL_DB" --instance="$SQL_INSTANCE"

SQL_IP="$(gc sql instances describe "$SQL_INSTANCE" --format='value(ipAddresses[0].ipAddress)')"
echo
echo "Cloud SQL private IP: ${SQL_IP}"
echo "Done."

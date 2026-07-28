#!/usr/bin/env bash
# Shared settings for the Warmbly GCP deployment scripts. Source this first.
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-warmbly-503807}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"

# Artifact Registry
export AR_REPO="${AR_REPO:-warmbly}"
export AR_HOST="${REGION}-docker.pkg.dev"
export IMAGE_BASE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}"

# Cloud SQL
export SQL_INSTANCE="${SQL_INSTANCE:-warmbly-pg}"
export SQL_TIER="${SQL_TIER:-db-g1-small}"
export SQL_DB="${SQL_DB:-warmbly}"
export SQL_USER="${SQL_USER:-warmbly}"

# Service accounts
export RUN_SA="warmbly-run@${PROJECT_ID}.iam.gserviceaccount.com"
export WORKER_SA="warmbly-worker@${PROJECT_ID}.iam.gserviceaccount.com"

# Worker VM (single worker: Gmail API sending makes an IP fleet pointless)
export WORKER_VM="${WORKER_VM:-warmbly-worker}"
# e2-medium (4GB): Redis + NATS + the worker share this box. e2-small's 2GB is
# too tight once the worker holds IMAP connections.
export WORKER_MACHINE="${WORKER_MACHINE:-e2-medium}"

# Budget
export BUDGET_AMOUNT="${BUDGET_AMOUNT:-100}"

gc() { gcloud --project "$PROJECT_ID" "$@"; }
export -f gc

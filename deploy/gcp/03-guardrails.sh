#!/usr/bin/env bash
# Cost guardrails: a billing budget with alert thresholds. Cloud Run
# max-instances are set at deploy time in 07-deploy-run.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

gc services enable billingbudgets.googleapis.com >/dev/null

BILLING_ACCOUNT="$(gc billing projects describe "$PROJECT_ID" --format='value(billingAccountName)')"
BILLING_ACCOUNT="${BILLING_ACCOUNT#billingAccounts/}"

if CLOUDSDK_CORE_PROJECT="$PROJECT_ID" gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
     --format="value(displayName)" 2>/dev/null | grep -qx "warmbly-monthly"; then
  echo "budget 'warmbly-monthly' already exists"
  exit 0
fi

CLOUDSDK_CORE_PROJECT="$PROJECT_ID" gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="warmbly-monthly" \
  --budget-amount="${BUDGET_AMOUNT}USD" \
  --filter-projects="projects/$(gc projects describe "$PROJECT_ID" --format='value(projectNumber)')" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.0,basis=forecasted-spend

echo "Budget set at \$${BUDGET_AMOUNT}/mo with alerts at 50/90/100% and forecast-100%."

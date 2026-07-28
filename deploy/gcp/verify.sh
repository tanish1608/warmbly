#!/usr/bin/env bash
# Post-deploy smoke check. Reports every component; exits non-zero if any fail.
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

fails=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }

# Ask Cloud Run for the URL rather than assembling the project-number form:
# both resolve eventually, but DNS for a freshly created service can lag.
url_for() { gc run services describe "warmbly-$1" --region="$REGION" --format='value(status.url)'; }

echo "Cloud Run services"
for s in backend realtime web admin tracking; do
  st="$(gc run services describe "warmbly-${s}" --region="$REGION" \
        --format='value(status.conditions[0].status)' 2>/dev/null || echo MISSING)"
  [ "$st" = "True" ] && ok "warmbly-${s} ready" || bad "warmbly-${s} not ready ($st)"
done

echo "HTTP endpoints"
for pair in "backend:/health" "tracking:/health" "web:/" "admin:/"; do
  svc="${pair%%:*}"; path="${pair#*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$(url_for "$svc")${path}")"
  [ "$code" = "200" ] && ok "${svc}${path} -> 200" || bad "${svc}${path} -> ${code}"
done

echo "Data plane"
sql_state="$(gc sql instances describe "$SQL_INSTANCE" --format='value(state)' 2>/dev/null || echo MISSING)"
[ "$sql_state" = "RUNNABLE" ] && ok "cloud sql ${SQL_INSTANCE} runnable" || bad "cloud sql ${sql_state}"

vm_state="$(gc compute instances describe "$WORKER_VM" --zone="$ZONE" --format='value(status)' 2>/dev/null || echo MISSING)"
[ "$vm_state" = "RUNNING" ] && ok "vm ${WORKER_VM} running" || bad "vm ${vm_state}"

echo "VM services (redis, nats, consumer, worker)"
vm_units="$(gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap \
  --command 'systemctl is-active redis nats warmbly-consumer warmbly-worker 2>/dev/null | tr "\n" " "' 2>/dev/null | tail -1)"
i=0
for u in redis nats warmbly-consumer warmbly-worker; do
  i=$((i+1))
  state="$(echo "$vm_units" | cut -d' ' -f$i)"
  [ "$state" = "active" ] && ok "${u} active" || bad "${u} ${state:-unknown}"
done

echo "Event bus"
conns="$(gc compute ssh "$WORKER_VM" --zone="$ZONE" --tunnel-through-iap \
  --command 'curl -s http://localhost:8222/varz | grep -o "\"connections\": *[0-9]*" | grep -o "[0-9]*"' 2>/dev/null | tail -1)"
[ "${conns:-0}" -gt 0 ] 2>/dev/null && ok "nats has ${conns} client(s)" || bad "nats has no clients"

echo "OAuth secrets"
for s in box-google-client-id box-google-client-secret; do
  v="$(gc secrets versions access latest --secret="warmbly-${s}" 2>/dev/null || echo)"
  [ -n "$v" ] && [ "$v" != "PLACEHOLDER" ] \
    && ok "warmbly-${s} set" \
    || bad "warmbly-${s} still PLACEHOLDER (see 05-oauth.md)"
done

echo
[ "$fails" -eq 0 ] && echo "All checks passed." || echo "${fails} check(s) failed."
exit "$fails"

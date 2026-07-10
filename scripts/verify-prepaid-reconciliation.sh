#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
PARTNER="${PREPAID_PARTNER_ID:-prepaid-fintech-br-001}"
SHOW_JSON="${SHOW_JSON:-false}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prepaid-reconciliation.XXXXXX")"
cleanup() {
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  else
    printf '[prepaid][DEBUG] Preserving diagnostic files in %s\n'       "$WORK_DIR" >&2
  fi
}

trap cleanup EXIT

ok() { printf '[prepaid][PASS] %s\n' "$*"; }
step() { printf '\n[prepaid][STEP] %s\n' "$*"; }
fail() { printf '[prepaid][FAIL] %s\n' "$*" >&2; exit 1; }
show() { [[ "$SHOW_JSON" == true ]] && jq . "$1" || true; }
for command in curl jq; do command -v "$command" >/dev/null 2>&1 || fail "$command is required"; done

wait_url() {
  local url="$1" label="$2"
  for _ in $(seq 1 60); do
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && { ok "$label is ready"; return; }
    sleep 2
  done
  fail "$label did not become ready: $url"
}
wallet_balance() { curl -fsS "$STORE_URL/wallets/$PARTNER" | jq -r '.wallet.balance'; }
assert_balance() {
  local expected="$1" actual
  actual="$(wallet_balance)"
  jq -ne --argjson a "$actual" --argjson e "$expected" '((($a-$e)|if .<0 then -. else . end) < 0.000001)' >/dev/null \
    || fail "Expected wallet $expected, found $actual"
  ok "Wallet balance is BRL $expected"
}
invoke() {
  local cid="$1" operation="$2" body="$3" output="$4" code
  code="$(curl -sS -o "$output" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "X-Correlation-ID: $cid" \
    -d "$body" "$MI_URL/secure-mobile-transactions/v1/$operation")"
  [[ "$code" == 200 ]] || fail "$operation returned HTTP $code: $(cat "$output")"
}

wait_url "$STORE_URL/health" 'Commercial store'
wait_url "$MI_URL/secure-mobile-transactions/v1/health" 'MI commercial API'

step 'Reset only the dedicated prepaid partner'
curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
  "$STORE_URL/demo/partners/$PARTNER/reset" >/dev/null

step 'Use the existing Business plan with PREPAID settlement'
curl -fsS -X PUT -H 'Content-Type: application/json' \
  -d '{"planId":"Business","billingMode":"PREPAID","country":"BR","currency":"BRL","contractReference":"DEMO-PREPAID-BR"}' \
  "$MI_URL/secure-mobile-transactions/v1/partners/$PARTNER/plan" > "$WORK_DIR/assignment.json"
jq -e '.assignment.planId == "Business" and .assignment.billingMode == "PREPAID"' "$WORK_DIR/assignment.json" >/dev/null \
  || fail 'Prepaid assignment failed'
ok 'Business plan assigned in prepaid mode'; show "$WORK_DIR/assignment.json"

step 'Consume the existing 10,000-call allowance'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"partnerId\":\"$PARTNER\",\"apiProduct\":\"SecureMobileTransactionsProduct\",\"meter\":\"number_verification\",\"successfulRequests\":10000,\"rejectedRequests\":0,\"billedAmount\":0}" \
  "$MI_URL/secure-mobile-transactions/v1/demo/seed" > "$WORK_DIR/seed.json"
jq -e '.usage.overLimit == true' "$WORK_DIR/seed.json" >/dev/null || fail 'Allowance exhaustion failed'
ok 'Business overage prices are active'

step 'Top up BRL 0.57 and prove top-up idempotency'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"amount":0.57,"reference":"initial-topup"}' "$STORE_URL/wallets/$PARTNER/topups" > "$WORK_DIR/topup.json"
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"amount":0.57,"reference":"initial-topup"}' "$STORE_URL/wallets/$PARTNER/topups" > "$WORK_DIR/topup-replay.json"
jq -e '.idempotentReplay == false and .wallet.balance == 0.57' "$WORK_DIR/topup.json" >/dev/null || fail 'Top-up failed'
jq -e '.idempotentReplay == true and .wallet.balance == 0.57' "$WORK_DIR/topup-replay.json" >/dev/null || fail 'Top-up replay failed'
ok 'Duplicate top-up did not add funds twice'; show "$WORK_DIR/topup.json"

step 'Number Verification costs BRL 0.08'
invoke prepaid-nv-1 number-verification \
  "{\"partnerId\":\"$PARTNER\",\"msisdn\":\"+5511999990001\",\"consentId\":\"prepaid-nv-1\",\"country\":\"BR\",\"currency\":\"BRL\"}" "$WORK_DIR/nv1.json"
jq -e '.commercialUsage.billedAmount == 0.08' "$WORK_DIR/nv1.json" >/dev/null || fail 'NV rating failed'
assert_balance 0.49; show "$WORK_DIR/nv1.json"

step 'SIM Swap costs BRL 0.14'
invoke prepaid-sim-1 sim-swap \
  "{\"partnerId\":\"$PARTNER\",\"msisdn\":\"+5511999990001\",\"consentId\":\"prepaid-sim-1\",\"country\":\"BR\",\"currency\":\"BRL\"}" "$WORK_DIR/sim1.json"
jq -e '.commercialUsage.billedAmount == 0.14' "$WORK_DIR/sim1.json" >/dev/null || fail 'SIM rating failed'
assert_balance 0.35; show "$WORK_DIR/sim1.json"

step 'Quality on Demand costs BRL 0.35'
invoke prepaid-qod-1 quality-on-demand \
  "{\"partnerId\":\"$PARTNER\",\"consentId\":\"prepaid-qod-1\",\"profile\":\"QOS_E\",\"durationSeconds\":900,\"country\":\"BR\",\"currency\":\"BRL\"}" "$WORK_DIR/qod1.json"
jq -e '.commercialUsage.billedAmount == 0.35' "$WORK_DIR/qod1.json" >/dev/null || fail 'QoD rating failed'
assert_balance 0; show "$WORK_DIR/qod1.json"

step 'Reject the next request before backend execution'
curl -fsS "$MI_URL/secure-mobile-transactions/v1/partners/$PARTNER/usage" > "$WORK_DIR/before.json"
COUNT_BEFORE="$(jq '.recentEvents | length' "$WORK_DIR/before.json")"
CODE="$(curl -sS -o "$WORK_DIR/exhausted.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-Correlation-ID: prepaid-exhausted' \
  -d "{\"partnerId\":\"$PARTNER\",\"msisdn\":\"+5511999990001\",\"consentId\":\"prepaid-exhausted\",\"country\":\"BR\",\"currency\":\"BRL\"}" \
  "$MI_URL/secure-mobile-transactions/v1/number-verification")"
[[ "$CODE" == 402 ]] || fail "Expected 402, got $CODE: $(cat "$WORK_DIR/exhausted.json")"
if ! jq -e '.code == "PREPAID_CREDIT_EXHAUSTED" and .requiredAmount == 0.08 and .availableBalance == 0' \
    "$WORK_DIR/exhausted.json" >/dev/null 2>&1; then
  printf '[prepaid][DEBUG] Raw HTTP 402 response body:\n' >&2
  cat "$WORK_DIR/exhausted.json" >&2
  printf '\n' >&2
  fail 'Exhaustion payload is incorrect or is not valid JSON'
fi
curl -fsS "$MI_URL/secure-mobile-transactions/v1/partners/$PARTNER/usage" > "$WORK_DIR/after.json"
[[ "$COUNT_BEFORE" == "$(jq '.recentEvents | length' "$WORK_DIR/after.json")" ]] || fail 'Rejected request created an event'
ok 'HTTP 402 returned and backend usage did not advance'; show "$WORK_DIR/exhausted.json"

step 'Top up BRL 0.20 and restore service'
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"amount":0.20,"reference":"recovery-topup"}' "$STORE_URL/wallets/$PARTNER/topups" >/dev/null
invoke prepaid-nv-2 number-verification \
  "{\"partnerId\":\"$PARTNER\",\"msisdn\":\"+5511999990001\",\"consentId\":\"prepaid-nv-2\",\"country\":\"BR\",\"currency\":\"BRL\"}" "$WORK_DIR/nv2.json"
assert_balance 0.12

step 'Create one missing and one incorrect settlement record'
curl -fsS "$MI_URL/secure-mobile-transactions/v1/partners/$PARTNER/usage" > "$WORK_DIR/usage.json"
event_id() { jq -r --arg cid "$1" '.recentEvents[] | select(.correlationId == $cid) | .eventId' "$WORK_DIR/usage.json"; }
NV1="$(event_id prepaid-nv-1)"; SIM1="$(event_id prepaid-sim-1)"; QOD1="$(event_id prepaid-qod-1)"; NV2="$(event_id prepaid-nv-2)"
for id in "$NV1" "$SIM1" "$QOD1" "$NV2"; do [[ -n "$id" && "$id" != null ]] || fail 'Could not resolve event IDs'; done
put_record() {
  curl -fsS -X PUT -H 'Content-Type: application/json' \
    -d "{\"partnerId\":\"$PARTNER\",\"amount\":$2,\"currency\":\"BRL\",\"source\":\"mock-amx-settlement\"}" \
    "$STORE_URL/settlement-records/$1" >/dev/null
}
put_record "$NV1" 0.08
# SIM1 intentionally missing.
put_record "$QOD1" 0.30
put_record "$NV2" 0.08
curl -fsS "$STORE_URL/reconciliation?partnerId=$PARTNER" > "$WORK_DIR/recon-before.json"
jq -e '.discrepancyCount == 2 and any(.discrepancies[]; .type == "MISSING_SETTLEMENT_RECORD") and any(.discrepancies[]; .type == "AMOUNT_MISMATCH")' \
  "$WORK_DIR/recon-before.json" >/dev/null || fail 'Expected reconciliation differences were not found'
ok 'Reconciliation found one missing record and one amount mismatch'; show "$WORK_DIR/recon-before.json"

step 'Replay the authoritative events and converge reconciliation'
for id in "$SIM1" "$QOD1"; do
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"eventId\":\"$id\"}" \
    "$STORE_URL/reconciliation/replay" >/dev/null
done
curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"eventId\":\"$SIM1\"}" \
  "$STORE_URL/reconciliation/replay" >/dev/null
curl -fsS "$STORE_URL/reconciliation?partnerId=$PARTNER" > "$WORK_DIR/recon-after.json"
jq -e '.reconciled == true and .discrepancyCount == 0 and .ledger.records == .settlement.records' \
  "$WORK_DIR/recon-after.json" >/dev/null || fail 'Reconciliation did not converge'
ok 'Final reconciliation is clean and replay is idempotent'; show "$WORK_DIR/recon-after.json"
printf '\n[PASS] Prepaid exhaustion + commercial reconciliation completed for %s.\n' "$PARTNER"

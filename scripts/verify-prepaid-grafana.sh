#!/usr/bin/env bash
set -Eeuo pipefail

STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

PARTNER="${PREPAID_PARTNER_ID:-prepaid-fintech-br-001}"

WAIT_ATTEMPTS="${PREPAID_GRAFANA_WAIT_ATTEMPTS:-45}"
WAIT_SECONDS="${PREPAID_GRAFANA_WAIT_SECONDS:-2}"

pass() {
  printf '[prepaid-grafana][PASS] %s\n' "$*"
}

info() {
  printf '[prepaid-grafana] %s\n' "$*"
}

fail() {
  printf '[prepaid-grafana][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "$command is required."
done

prometheus_value() {
  local query="$1"

  curl \
    --fail \
    --silent \
    --show-error \
    --get \
    --data-urlencode "query=$query" \
    "$PROMETHEUS_URL/api/v1/query" |
    jq -r '
      if
        .status == "success"
        and (.data.result | length) > 0
      then
        .data.result[0].value[1]
      else
        empty
      end
    '
}

numeric_equal() {
  local actual="$1"
  local expected="$2"

  jq -ne \
    --arg actual "$actual" \
    --arg expected "$expected" '
      ($actual | tonumber) as $a
      | ($expected | tonumber) as $e
      | (($a - $e) | if . < 0 then -. else . end) < 0.000001
    ' >/dev/null
}

numeric_at_least() {
  local actual="$1"
  local minimum="$2"

  jq -ne \
    --arg actual "$actual" \
    --arg minimum "$minimum" '
      ($actual | tonumber) >= ($minimum | tonumber)
    ' >/dev/null
}

wait_for_exact_value() {
  local description="$1"
  local query="$2"
  local expected="$3"
  local value=""
  local attempt

  for attempt in $(seq 1 "$WAIT_ATTEMPTS"); do
    value="$(prometheus_value "$query" 2>/dev/null || true)"

    if [[ -n "$value" ]] &&
       numeric_equal "$value" "$expected"; then
      printf '%s' "$value"
      return 0
    fi

    if (( attempt % 5 == 0 )); then
      printf \
        '[prepaid-grafana] Waiting for %s=%s; last value=%s\n' \
        "$description" \
        "$expected" \
        "${value:-missing}" \
        >&2
    fi

    sleep "$WAIT_SECONDS"
  done

  fail \
    "Timed out waiting for $description=$expected; " \
    "last value=${value:-missing}; query=$query"
}

wait_for_minimum_value() {
  local description="$1"
  local query="$2"
  local minimum="$3"
  local value=""
  local attempt

  for attempt in $(seq 1 "$WAIT_ATTEMPTS"); do
    value="$(prometheus_value "$query" 2>/dev/null || true)"

    if [[ -n "$value" ]] &&
       numeric_at_least "$value" "$minimum"; then
      printf '%s' "$value"
      return 0
    fi

    if (( attempt % 5 == 0 )); then
      printf \
        '[prepaid-grafana] Waiting for %s>=%s; last value=%s\n' \
        "$description" \
        "$minimum" \
        "${value:-missing}" \
        >&2
    fi

    sleep "$WAIT_SECONDS"
  done

  fail \
    "Timed out waiting for $description>=$minimum; " \
    "last value=${value:-missing}; query=$query"
}

# ---------------------------------------------------------------------------
# Confirm the meter store exposes all required metric families.
# ---------------------------------------------------------------------------

metrics="$(
  curl --fail --silent --show-error "$STORE_URL/metrics"
)" || fail "Commercial meter-store metrics endpoint is unavailable."

required_metrics=(
  telco_prepaid_wallet_balance
  telco_prepaid_wallet_topup_amount_total
  telco_prepaid_wallet_debited_amount_total
  telco_prepaid_credit_denials_total
  telco_commercial_reconciliation_reconciled
  telco_commercial_reconciliation_discrepancies
  telco_commercial_reconciliation_ledger_records
  telco_commercial_reconciliation_settlement_records
  telco_commercial_reconciliation_ledger_amount
  telco_commercial_reconciliation_settlement_amount
)

for metric in "${required_metrics[@]}"; do
  grep -Fq "$metric" <<<"$metrics" ||
    fail "Metric is missing from the store: $metric"
done

pass "Commercial meter store exposes prepaid and reconciliation metrics"

# ---------------------------------------------------------------------------
# Confirm the authoritative file-backed store has the expected final state.
# ---------------------------------------------------------------------------

wallet_json="$(
  curl \
    --fail \
    --silent \
    --show-error \
    "$STORE_URL/wallets/$PARTNER"
)" || fail "Could not retrieve the prepaid wallet."

store_balance="$(
  jq -r '.wallet.balance // empty' <<<"$wallet_json"
)"

[[ -n "$store_balance" ]] ||
  fail "The wallet response does not contain wallet.balance."

numeric_equal "$store_balance" "0.12" ||
  fail \
    "Expected authoritative balance 0.12; found $store_balance."

pass "Authoritative meter-store wallet balance is BRL 0.12"

reconciliation_json="$(
  curl \
    --fail \
    --silent \
    --show-error \
    "$STORE_URL/reconciliation?partnerId=$PARTNER"
)" || fail "Could not retrieve the reconciliation report."

store_reconciled="$(
  jq -r '.reconciled // false' <<<"$reconciliation_json"
)"

store_discrepancies="$(
  jq -r '.discrepancyCount // -1' <<<"$reconciliation_json"
)"

[[ "$store_reconciled" == "true" ]] ||
  fail "The authoritative reconciliation report is not reconciled."

[[ "$store_discrepancies" == "0" ]] ||
  fail \
    "Expected zero authoritative discrepancies; " \
    "found $store_discrepancies."

pass "Authoritative commercial reconciliation is clean"

# ---------------------------------------------------------------------------
# Wait for Prometheus without assuming job or instance label values.
#
# max(...) tolerates a changed job name and also avoids double-counting if
# more than one equivalent target is temporarily present.
# ---------------------------------------------------------------------------

series_query="count(telco_prepaid_wallet_balance{partner=\"$PARTNER\"})"

info "Waiting for Prometheus to discover the prepaid metric series."

series_count="$(
  wait_for_minimum_value \
    "prepaid wallet metric-series count" \
    "$series_query" \
    "1"
)"

pass "Prometheus is scraping the prepaid wallet metrics"

balance_query="max(telco_prepaid_wallet_balance{partner=\"$PARTNER\"})"

balance="$(
  wait_for_exact_value \
    "prepaid wallet balance" \
    "$balance_query" \
    "0.12"
)"

pass "Prometheus contains the final BRL 0.12 wallet balance"

denial_query="max(telco_prepaid_credit_denials_total{partner=\"$PARTNER\"})"

denials="$(
  wait_for_minimum_value \
    "prepaid credit denials" \
    "$denial_query" \
    "1"
)"

pass "Prometheus proves at least one credit-exhaustion rejection"

reconciled_query="max(telco_commercial_reconciliation_reconciled{partner=\"$PARTNER\"})"

reconciled="$(
  wait_for_exact_value \
    "reconciliation status" \
    "$reconciled_query" \
    "1"
)"

pass "Prometheus reports a clean final reconciliation"

discrepancy_query="max(telco_commercial_reconciliation_discrepancies{partner=\"$PARTNER\"})"

discrepancies="$(
  wait_for_exact_value \
    "reconciliation discrepancies" \
    "$discrepancy_query" \
    "0"
)"

pass "Prometheus reports zero final reconciliation discrepancies"

topup_query="max(telco_prepaid_wallet_topup_amount_total{partner=\"$PARTNER\"})"

topups="$(
  wait_for_exact_value \
    "total prepaid top-ups" \
    "$topup_query" \
    "0.77"
)"

pass "Prometheus reports BRL 0.77 in total top-ups"

debit_query="max(telco_prepaid_wallet_debited_amount_total{partner=\"$PARTNER\"})"

debits="$(
  wait_for_exact_value \
    "total prepaid debits" \
    "$debit_query" \
    "0.65"
)"

pass "Prometheus reports BRL 0.65 in total debits"

ledger_amount_query="max(telco_commercial_reconciliation_ledger_amount{partner=\"$PARTNER\"})"

ledger_amount="$(
  wait_for_exact_value \
    "usage-ledger amount" \
    "$ledger_amount_query" \
    "0.65"
)"

settlement_amount_query="max(telco_commercial_reconciliation_settlement_amount{partner=\"$PARTNER\"})"

settlement_amount="$(
  wait_for_exact_value \
    "settlement amount" \
    "$settlement_amount_query" \
    "0.65"
)"

pass "Prometheus reports matching BRL 0.65 ledger and settlement amounts"

ledger_records_query="max(telco_commercial_reconciliation_ledger_records{partner=\"$PARTNER\"})"

ledger_records="$(
  wait_for_exact_value \
    "usage-ledger record count" \
    "$ledger_records_query" \
    "4"
)"

settlement_records_query="max(telco_commercial_reconciliation_settlement_records{partner=\"$PARTNER\"})"

settlement_records="$(
  wait_for_exact_value \
    "settlement record count" \
    "$settlement_records_query" \
    "4"
)"

pass "Prometheus reports four ledger and four settlement records"

# ---------------------------------------------------------------------------
# Confirm that Grafana provisioned the dashboard.
# ---------------------------------------------------------------------------

dashboard_json=""
dashboard_uid=""
attempt=""

for attempt in $(seq 1 "$WAIT_ATTEMPTS"); do
  dashboard_json="$(
    curl \
      --fail \
      --silent \
      --show-error \
      -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
      "$GRAFANA_URL/api/dashboards/uid/prepaid-wallet-reconciliation" \
      2>/dev/null ||
      true
  )"

  dashboard_uid="$(
    jq -r \
      '.dashboard.uid // empty' \
      <<<"${dashboard_json:-{}}" \
      2>/dev/null ||
      true
  )"

  if [[ "$dashboard_uid" == "prepaid-wallet-reconciliation" ]]; then
    break
  fi

  if (( attempt % 5 == 0 )); then
    info "Waiting for Grafana dashboard provisioning."
  fi

  sleep "$WAIT_SECONDS"
done

[[ "$dashboard_uid" == "prepaid-wallet-reconciliation" ]] ||
  fail "Grafana did not provision the prepaid wallet dashboard."

dashboard_title="$(
  jq -r '.dashboard.title // empty' <<<"$dashboard_json"
)"

pass "Grafana provisioned: $dashboard_title"

printf '\n'
printf '[PASS] Prepaid Grafana observability is synchronized and complete.\n'

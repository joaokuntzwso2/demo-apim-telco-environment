#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

VERIFY_FILE="scripts/verify-prepaid-grafana.sh"

fail() {
  printf '[fix-prepaid-grafana][FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[fix-prepaid-grafana][PASS] %s\n' "$*"
}

[[ -s "$VERIFY_FILE" ]] ||
  fail "Missing or empty file: $VERIFY_FILE"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/grafana-race-$STAMP"

mkdir -p "$BACKUP_DIR/scripts"
cp "$VERIFY_FILE" "$BACKUP_DIR/$VERIFY_FILE"

cat > "$VERIFY_FILE" <<'VERIFY'
#!/usr/bin/env bash
set -Eeuo pipefail

STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

PARTNER="${PREPAID_PARTNER_ID:-prepaid-fintech-br-001}"

PROMETHEUS_JOB="${PREPAID_PROMETHEUS_JOB:-commercial-meter-store}"
PROMETHEUS_INSTANCE="${PREPAID_PROMETHEUS_INSTANCE:-commercial-meter-store-primary:8086}"

WAIT_ATTEMPTS="${PREPAID_GRAFANA_WAIT_ATTEMPTS:-60}"
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

query_value() {
  local query="$1"

  curl -fsS \
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
      | ($a - $e) as $difference
      | (
          if $difference < 0
          then -$difference
          else $difference
          end
        ) < 0.000001
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

  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    value="$(query_value "$query" 2>/dev/null || true)"

    if [[ -n "$value" ]] &&
       numeric_equal "$value" "$expected"; then
      printf '%s' "$value"
      return 0
    fi

    sleep "$WAIT_SECONDS"
  done

  fail \
    "Timed out waiting for $description=$expected; " \
    "last observed value was ${value:-missing}"
}

wait_for_minimum_value() {
  local description="$1"
  local query="$2"
  local minimum="$3"
  local value=""

  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    value="$(query_value "$query" 2>/dev/null || true)"

    if [[ -n "$value" ]] &&
       numeric_at_least "$value" "$minimum"; then
      printf '%s' "$value"
      return 0
    fi

    sleep "$WAIT_SECONDS"
  done

  fail \
    "Timed out waiting for $description>=$minimum; " \
    "last observed value was ${value:-missing}"
}

# ---------------------------------------------------------------------------
# Meter-store metrics
# ---------------------------------------------------------------------------

metrics="$(
  curl -fsS "$STORE_URL/metrics"
)" || fail "Commercial metrics endpoint is unavailable."

for metric in \
  telco_prepaid_wallet_balance \
  telco_prepaid_wallet_topup_amount_total \
  telco_prepaid_wallet_debited_amount_total \
  telco_prepaid_credit_denials_total \
  telco_commercial_reconciliation_reconciled \
  telco_commercial_reconciliation_discrepancies \
  telco_commercial_reconciliation_ledger_records \
  telco_commercial_reconciliation_settlement_records \
  telco_commercial_reconciliation_ledger_amount \
  telco_commercial_reconciliation_settlement_amount
do
  grep -Fq "$metric" <<<"$metrics" ||
    fail "Metric is missing: $metric"
done

pass "Commercial meter store exposes prepaid and reconciliation metrics"

# ---------------------------------------------------------------------------
# Confirm the authoritative store has already reached its final state.
# ---------------------------------------------------------------------------

wallet_json="$(
  curl -fsS "$STORE_URL/wallets/$PARTNER"
)" || fail "Could not read the prepaid wallet from the meter store."

store_balance="$(
  jq -r '.wallet.balance // empty' <<<"$wallet_json"
)"

[[ -n "$store_balance" ]] ||
  fail "The meter-store wallet response does not contain a balance."

numeric_equal "$store_balance" "0.12" ||
  fail \
    "The authoritative meter-store balance should be 0.12; " \
    "found $store_balance"

pass "Authoritative meter-store wallet balance is BRL 0.12"

reconciliation_json="$(
  curl -fsS \
    "$STORE_URL/reconciliation?partnerId=$PARTNER"
)" || fail "Could not read the reconciliation report."

store_reconciled="$(
  jq -r '.reconciled // false' <<<"$reconciliation_json"
)"

store_discrepancies="$(
  jq -r '.discrepancyCount // -1' <<<"$reconciliation_json"
)"

[[ "$store_reconciled" == "true" ]] ||
  fail "The authoritative reconciliation report is not clean."

[[ "$store_discrepancies" == "0" ]] ||
  fail \
    "The authoritative reconciliation report contains " \
    "$store_discrepancies discrepancy/discrepancies."

pass "Authoritative commercial reconciliation is clean"

# ---------------------------------------------------------------------------
# Wait for Prometheus to scrape the final state.
# ---------------------------------------------------------------------------

target_query="up{
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

target_up="$(
  wait_for_exact_value \
    "commercial meter-store Prometheus target" \
    "$target_query" \
    "1"
)"

pass "Prometheus primary commercial meter-store target is up"

balance_query="telco_prepaid_wallet_balance{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

info "Waiting for Prometheus to observe the final BRL 0.12 balance."

balance="$(
  wait_for_exact_value \
    "prepaid wallet balance" \
    "$balance_query" \
    "0.12"
)"

pass "Prometheus contains the final BRL 0.12 wallet balance"

denial_query="sum(
  telco_prepaid_credit_denials_total{
    partner=\"$PARTNER\",
    job=\"$PROMETHEUS_JOB\",
    instance=\"$PROMETHEUS_INSTANCE\"
  }
)"

denials="$(
  wait_for_minimum_value \
    "prepaid credit denials" \
    "$denial_query" \
    "1"
)"

pass "Prometheus proves at least one credit-exhaustion rejection"

reconciled_query="telco_commercial_reconciliation_reconciled{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

reconciled="$(
  wait_for_exact_value \
    "reconciliation status" \
    "$reconciled_query" \
    "1"
)"

pass "Prometheus reports a clean final reconciliation"

discrepancy_query="sum(
  telco_commercial_reconciliation_discrepancies{
    partner=\"$PARTNER\",
    job=\"$PROMETHEUS_JOB\",
    instance=\"$PROMETHEUS_INSTANCE\"
  }
)"

discrepancies="$(
  wait_for_exact_value \
    "reconciliation discrepancies" \
    "$discrepancy_query" \
    "0"
)"

pass "Prometheus reports zero final reconciliation discrepancies"

topup_query="telco_prepaid_wallet_topup_amount_total{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

topups="$(
  wait_for_exact_value \
    "total prepaid top-ups" \
    "$topup_query" \
    "0.77"
)"

pass "Prometheus reports BRL 0.77 in total top-ups"

debit_query="telco_prepaid_wallet_debited_amount_total{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

debits="$(
  wait_for_exact_value \
    "total prepaid debits" \
    "$debit_query" \
    "0.65"
)"

pass "Prometheus reports BRL 0.65 in total debits"

ledger_amount_query="telco_commercial_reconciliation_ledger_amount{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

ledger_amount="$(
  wait_for_exact_value \
    "usage-ledger amount" \
    "$ledger_amount_query" \
    "0.65"
)"

settlement_amount_query="telco_commercial_reconciliation_settlement_amount{
  partner=\"$PARTNER\",
  job=\"$PROMETHEUS_JOB\",
  instance=\"$PROMETHEUS_INSTANCE\"
}"

settlement_amount="$(
  wait_for_exact_value \
    "settlement amount" \
    "$settlement_amount_query" \
    "0.65"
)"

pass "Prometheus reports matching BRL 0.65 ledger and settlement amounts"

# ---------------------------------------------------------------------------
# Grafana provisioning
# ---------------------------------------------------------------------------

dashboard=""

for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  dashboard="$(
    curl -fsS \
      -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
      "$GRAFANA_URL/api/dashboards/uid/prepaid-wallet-reconciliation" \
      2>/dev/null ||
      true
  )"

  dashboard_uid="$(
    jq -r \
      '.dashboard.uid // empty' \
      <<<"${dashboard:-{}}" \
      2>/dev/null ||
      true
  )"

  if [[ "$dashboard_uid" == "prepaid-wallet-reconciliation" ]]; then
    break
  fi

  sleep "$WAIT_SECONDS"
done

dashboard_uid="$(
  jq -r \
    '.dashboard.uid // empty' \
    <<<"${dashboard:-{}}" \
    2>/dev/null ||
    true
)"

[[ "$dashboard_uid" == "prepaid-wallet-reconciliation" ]] ||
  fail "Grafana did not provision the prepaid wallet dashboard."

pass "Grafana provisioned Prepaid Wallet & Commercial Reconciliation"

printf '\n'
printf '[PASS] Prepaid Grafana observability is synchronized and complete.\n'
VERIFY

chmod +x "$VERIFY_FILE"

bash -n "$VERIFY_FILE"

ROLLBACK="$BACKUP_DIR/rollback.sh"

cat > "$ROLLBACK" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail

cd "$ROOT_DIR"

cp "$BACKUP_DIR/$VERIFY_FILE" "$VERIFY_FILE"

printf '[rollback][PASS] Restored %s from %s\n' \
  "$VERIFY_FILE" \
  "$BACKUP_DIR"
ROLLBACK

chmod +x "$ROLLBACK"

pass "Grafana verifier now waits for the final Prometheus scrape."
printf '\nBackup:   %s\n' "$BACKUP_DIR"
printf 'Rollback: bash %s\n' "$ROLLBACK"

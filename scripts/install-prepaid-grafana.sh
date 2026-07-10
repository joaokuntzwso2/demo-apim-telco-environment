#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$(pwd)}"
cd "$ROOT_DIR"

EXT_JS="services/commercial-meter-store/src/prepaid-commercial-extension.js"
SERVER_JS="services/commercial-meter-store/src/server.js"
PROMETHEUS_YML="observability/prometheus/prometheus.yml"
DASHBOARD_JSON="observability/grafana/dashboards/prepaid-wallet-reconciliation.json"
RESET_SCRIPT="scripts/reset-with-telco-ai.sh"
WIRING_VERIFY="scripts/verify-prepaid-reset-wiring.sh"
GRAFANA_VERIFY="scripts/verify-prepaid-grafana.sh"

fail() { printf '[prepaid-grafana-install][FAIL] %s\n' "$*" >&2; exit 1; }
ok() { printf '[prepaid-grafana-install][OK] %s\n' "$*"; }

[[ -f docker-compose.yml ]] || fail "Run from the repository root."
for file in "$EXT_JS" "$SERVER_JS" "$PROMETHEUS_YML" "$RESET_SCRIPT"; do
  [[ -s "$file" ]] || fail "Missing or empty file: $file"
done
for command in python3 node jq; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required."
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/grafana-$STAMP"
mkdir -p "$BACKUP_DIR/$(dirname "$EXT_JS")" \
         "$BACKUP_DIR/$(dirname "$SERVER_JS")" \
         "$BACKUP_DIR/$(dirname "$PROMETHEUS_YML")" \
         "$BACKUP_DIR/$(dirname "$RESET_SCRIPT")"
cp "$EXT_JS" "$BACKUP_DIR/$EXT_JS"
cp "$SERVER_JS" "$BACKUP_DIR/$SERVER_JS"
cp "$PROMETHEUS_YML" "$BACKUP_DIR/$PROMETHEUS_YML"
cp "$RESET_SCRIPT" "$BACKUP_DIR/$RESET_SCRIPT"
for file in "$DASHBOARD_JSON" "$WIRING_VERIFY" "$GRAFANA_VERIFY"; do
  if [[ -f "$file" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
    cp "$file" "$BACKUP_DIR/$file"
  else
    printf '%s\n' "$file" >> "$BACKUP_DIR/created-files.txt"
  fi
done
ok "Backup created at $BACKUP_DIR"

python3 - "$EXT_JS" "$SERVER_JS" "$PROMETHEUS_YML" "$RESET_SCRIPT" "$WIRING_VERIFY" <<'PY'
from pathlib import Path
import sys

ext_path = Path(sys.argv[1])
server_path = Path(sys.argv[2])
prom_path = Path(sys.argv[3])
reset_path = Path(sys.argv[4])
wiring_path = Path(sys.argv[5])

ext = ext_path.read_text(encoding="utf-8")

# Persist a compact count of rejected prepaid preauthorizations.
if "state.prepaidCreditDenials" not in ext:
    needle = "  if (!state.settlementRecords) { state.settlementRecords = {}; changed = true; }"
    replacement = needle + "\n  if (!state.prepaidCreditDenials) { state.prepaidCreditDenials = {}; changed = true; }"
    if needle not in ext:
        raise SystemExit("Could not locate ensureState settlementRecords initialization.")
    ext = ext.replace(needle, replacement, 1)

# Record a denial before returning the controlled 402 through MI.
if "prepaid-denial" not in ext:
    old = """    const wallet = ensureWallet(state, partnerId, quote.assignment.currency);
    writeState(state);
    const authorized = money(wallet.balance) >= quote.quotedAmount;
    json(res, 200, {"""
    new = """    const wallet = ensureWallet(state, partnerId, quote.assignment.currency);
    const authorized = money(wallet.balance) >= quote.quotedAmount;
    if (!authorized) {
      const denialKey = `${partnerId}|${meter}|${wallet.currency}`;
      const denial = state.prepaidCreditDenials[denialKey] || {
        partnerId,
        meter,
        currency: wallet.currency,
        count: 0,
        lastDeniedAt: null
      };
      denial.count += 1;
      denial.lastDeniedAt = new Date().toISOString();
      state.prepaidCreditDenials[denialKey] = denial;
      logEvent('prepaid-denial', {
        correlationId,
        partnerId,
        meter,
        requiredAmount: quote.quotedAmount,
        availableBalance: money(wallet.balance),
        currency: wallet.currency
      });
    }
    writeState(state);
    json(res, 200, {"""
    if old not in ext:
        raise SystemExit("Could not locate prepaid preauthorization block.")
    ext = ext.replace(old, new, 1)

# Remove the dedicated partner's denial counters during scenario reset.
if "delete state.prepaidCreditDenials[denialKey]" not in ext:
    old = """    for (const [eventId, record] of Object.entries(state.settlementRecords)) {
      if (record.partnerId === partnerId) delete state.settlementRecords[eventId];
    }
    writeState(state);"""
    new = """    for (const [eventId, record] of Object.entries(state.settlementRecords)) {
      if (record.partnerId === partnerId) delete state.settlementRecords[eventId];
    }
    for (const [denialKey, denial] of Object.entries(state.prepaidCreditDenials)) {
      if (denial.partnerId === partnerId) delete state.prepaidCreditDenials[denialKey];
    }
    writeState(state);"""
    if old not in ext:
        raise SystemExit("Could not locate partner reset settlement cleanup.")
    ext = ext.replace(old, new, 1)

metrics_function = r'''
function appendPrometheusMetrics(state, lines, PLAN_CATALOG) {
  ensureState(state);

  lines.push(
    '# HELP telco_prepaid_wallet_balance Current prepaid wallet balance.',
    '# TYPE telco_prepaid_wallet_balance gauge',
    '# HELP telco_prepaid_wallet_topup_amount_total Total amount credited to the prepaid wallet.',
    '# TYPE telco_prepaid_wallet_topup_amount_total counter',
    '# HELP telco_prepaid_wallet_debited_amount_total Total amount debited from the prepaid wallet.',
    '# TYPE telco_prepaid_wallet_debited_amount_total counter',
    '# HELP telco_prepaid_wallet_transactions_total Prepaid wallet transactions by type.',
    '# TYPE telco_prepaid_wallet_transactions_total counter',
    '# HELP telco_prepaid_credit_denials_total Requests rejected because prepaid credit was insufficient.',
    '# TYPE telco_prepaid_credit_denials_total counter',
    '# HELP telco_commercial_reconciliation_reconciled Reconciliation status: 1 means clean, 0 means discrepancies exist.',
    '# TYPE telco_commercial_reconciliation_reconciled gauge',
    '# HELP telco_commercial_reconciliation_discrepancies Current reconciliation discrepancies by type.',
    '# TYPE telco_commercial_reconciliation_discrepancies gauge',
    '# HELP telco_commercial_reconciliation_ledger_records Usage-ledger records included in reconciliation.',
    '# TYPE telco_commercial_reconciliation_ledger_records gauge',
    '# HELP telco_commercial_reconciliation_settlement_records Downstream settlement records included in reconciliation.',
    '# TYPE telco_commercial_reconciliation_settlement_records gauge',
    '# HELP telco_commercial_reconciliation_ledger_amount Rated amount in the usage ledger.',
    '# TYPE telco_commercial_reconciliation_ledger_amount gauge',
    '# HELP telco_commercial_reconciliation_settlement_amount Amount present in downstream settlement records.',
    '# TYPE telco_commercial_reconciliation_settlement_amount gauge'
  );

  const esc = (value) => String(value ?? '')
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"');

  for (const [partnerId, wallet] of Object.entries(state.wallets || {}).sort()) {
    const assignment = state.assignments?.[partnerId];
    if (!assignment || assignment.billingMode !== 'PREPAID') continue;

    const plan = esc(assignment.planId || 'UNKNOWN');
    const partner = esc(partnerId);
    const currency = esc(wallet.currency || assignment.currency || 'BRL');
    const labels = `partner="${partner}",plan="${plan}",currency="${currency}"`;
    const transactions = wallet.transactions || [];
    const topups = transactions.filter((transaction) => transaction.type === 'TOPUP');
    const debits = transactions.filter((transaction) => transaction.type === 'DEBIT');
    const topupAmount = topups.reduce((sum, transaction) => sum + money(transaction.amount), 0);
    const debitedAmount = debits.reduce((sum, transaction) => sum + money(transaction.amount), 0);
    const reconciliation = buildReconciliation(state, partnerId);

    lines.push(`telco_prepaid_wallet_balance{${labels}} ${money(wallet.balance).toFixed(6)}`);
    lines.push(`telco_prepaid_wallet_topup_amount_total{${labels}} ${money(topupAmount).toFixed(6)}`);
    lines.push(`telco_prepaid_wallet_debited_amount_total{${labels}} ${money(debitedAmount).toFixed(6)}`);
    lines.push(`telco_prepaid_wallet_transactions_total{${labels},type="TOPUP"} ${topups.length}`);
    lines.push(`telco_prepaid_wallet_transactions_total{${labels},type="DEBIT"} ${debits.length}`);
    lines.push(`telco_commercial_reconciliation_reconciled{partner="${partner}"} ${reconciliation.reconciled ? 1 : 0}`);
    lines.push(`telco_commercial_reconciliation_ledger_records{partner="${partner}"} ${reconciliation.ledger.records}`);
    lines.push(`telco_commercial_reconciliation_settlement_records{partner="${partner}"} ${reconciliation.settlement.records}`);
    lines.push(`telco_commercial_reconciliation_ledger_amount{partner="${partner}",currency="${currency}"} ${money(reconciliation.ledger.totalAmount).toFixed(6)}`);
    lines.push(`telco_commercial_reconciliation_settlement_amount{partner="${partner}",currency="${currency}"} ${money(reconciliation.settlement.totalAmount).toFixed(6)}`);

    const discrepancyCounts = {
      MISSING_SETTLEMENT_RECORD: 0,
      AMOUNT_MISMATCH: 0,
      ORPHAN_SETTLEMENT_RECORD: 0
    };
    for (const discrepancy of reconciliation.discrepancies) {
      discrepancyCounts[discrepancy.type] = (discrepancyCounts[discrepancy.type] || 0) + 1;
    }
    for (const [type, count] of Object.entries(discrepancyCounts)) {
      lines.push(`telco_commercial_reconciliation_discrepancies{partner="${partner}",type="${esc(type)}"} ${count}`);
    }
  }

  for (const denial of Object.values(state.prepaidCreditDenials || {})) {
    lines.push(
      `telco_prepaid_credit_denials_total{partner="${esc(denial.partnerId)}",meter="${esc(denial.meter)}",currency="${esc(denial.currency)}"} ${Number(denial.count || 0)}`
    );
  }

  return `${lines.join('\n')}\n`;
}
'''

if "function appendPrometheusMetrics(" not in ext:
    marker = "\nmodule.exports = { applyPrepaidDebit, handleRequest };"
    if marker not in ext:
        raise SystemExit("Could not locate prepaid extension exports.")
    ext = ext.replace(
        marker,
        metrics_function + "\nmodule.exports = { applyPrepaidDebit, handleRequest, appendPrometheusMetrics };",
        1,
    )
elif "appendPrometheusMetrics };" not in ext:
    ext = ext.replace(
        "module.exports = { applyPrepaidDebit, handleRequest };",
        "module.exports = { applyPrepaidDebit, handleRequest, appendPrometheusMetrics };",
        1,
    )

ext_path.write_text(ext, encoding="utf-8")

server = server_path.read_text(encoding="utf-8")
if "prepaidCommercial.appendPrometheusMetrics(state, lines, PLAN_CATALOG)" not in server:
    old = "return `${lines.join('\\n')}\\n`;"
    new = "return prepaidCommercial.appendPrometheusMetrics(state, lines, PLAN_CATALOG);"
    if old not in server:
        raise SystemExit("Could not locate commercial metrics return statement.")
    server = server.replace(old, new, 1)
server_path.write_text(server, encoding="utf-8")

prom = prom_path.read_text(encoding="utf-8")
if "commercial-meter-store-primary:8086" not in prom:
    if not prom.endswith("\n"):
        prom += "\n"
    prom += """
  - job_name: commercial-meter-store
    metrics_path: /metrics
    static_configs:
      - targets: ['commercial-meter-store-primary:8086']
"""
prom_path.write_text(prom, encoding="utf-8")

reset = reset_path.read_text(encoding="utf-8")
if "verify-prepaid-grafana.sh" not in reset:
    anchor = 'pass "Prepaid credit exhaustion and commercial reconciliation"'
    addition = '''pass "Prepaid credit exhaustion and commercial reconciliation"

echo "[telco-ai-reset] Verifying prepaid Grafana observability."
bash scripts/verify-prepaid-grafana.sh
pass "Prepaid wallet and reconciliation Grafana dashboard"'''
    if anchor not in reset:
        raise SystemExit("Could not locate prepaid verification in reset-with-telco-ai.sh.")
    reset = reset.replace(anchor, addition, 1)
reset_path.write_text(reset, encoding="utf-8")

if wiring_path.exists():
    wiring = wiring_path.read_text(encoding="utf-8")
    if "prepaid-wallet-reconciliation.json" not in wiring:
        needle = 'PREPAID_DEMO="scripts/demo-prepaid-reconciliation.sh"'
        if needle in wiring:
            wiring = wiring.replace(
                needle,
                needle + '\nPREPAID_GRAFANA_VERIFY="scripts/verify-prepaid-grafana.sh"\nPREPAID_GRAFANA_DASHBOARD="observability/grafana/dashboards/prepaid-wallet-reconciliation.json"',
                1,
            )
        list_needle = '  "$PREPAID_DEMO" \\\n  docker-compose.commercial.yml'
        if list_needle in wiring:
            wiring = wiring.replace(
                list_needle,
                '  "$PREPAID_DEMO" \\\n  "$PREPAID_GRAFANA_VERIFY" \\\n  "$PREPAID_GRAFANA_DASHBOARD" \\\n  docker-compose.commercial.yml',
                1,
            )
        validation_anchor = 'require_text \\\n  "$RESET_SCRIPT" \\\n  "secure-mobile-transactions/v1/health"'
        if validation_anchor in wiring:
            wiring = wiring.replace(
                validation_anchor,
                validation_anchor + '''

require_text \\
  "$RESET_SCRIPT" \\
  "verify-prepaid-grafana.sh"

require_text \\
  "$EXT_JS" \\
  "telco_prepaid_wallet_balance"

require_text \\
  "observability/prometheus/prometheus.yml" \\
  "commercial-meter-store-primary:8086"''',
                1,
            )
        wiring_path.write_text(wiring, encoding="utf-8")
PY

cat > "$DASHBOARD_JSON" <<'JSON'
{
  "annotations": {"list": []},
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "type": "stat",
      "title": "Wallet balance (BRL)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_prepaid_wallet_balance{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 0, "y": 0}
    },
    {
      "type": "stat",
      "title": "Total topped up",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "sum(telco_prepaid_wallet_topup_amount_total{partner=\"$partner\"})", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 4, "y": 0}
    },
    {
      "type": "stat",
      "title": "Total debited",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "sum(telco_prepaid_wallet_debited_amount_total{partner=\"$partner\"})", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 8, "y": 0}
    },
    {
      "type": "stat",
      "title": "Credit denials",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "sum(telco_prepaid_credit_denials_total{partner=\"$partner\"})", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 12, "y": 0}
    },
    {
      "type": "stat",
      "title": "Reconciliation discrepancies",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "sum(telco_commercial_reconciliation_discrepancies{partner=\"$partner\"})", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 16, "y": 0}
    },
    {
      "type": "stat",
      "title": "Reconciliation status",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_reconciled{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {
        "defaults": {
          "decimals": 0,
          "mappings": [{"type": "value", "options": {"0": {"text": "ATTENTION"}, "1": {"text": "RECONCILED"}}}]
        },
        "overrides": []
      },
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 4, "x": 20, "y": 0}
    },
    {
      "type": "timeseries",
      "title": "Wallet balance over time",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_prepaid_wallet_balance{partner=\"$partner\"}", "legendFormat": "{{partner}} / {{currency}}", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "single", "sort": "none"}},
      "gridPos": {"h": 10, "w": 12, "x": 0, "y": 7}
    },
    {
      "type": "bargauge",
      "title": "Wallet transactions",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_prepaid_wallet_transactions_total{partner=\"$partner\"}", "legendFormat": "{{type}}", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"displayMode": "gradient", "orientation": "horizontal", "showUnfilled": true},
      "gridPos": {"h": 10, "w": 6, "x": 12, "y": 7}
    },
    {
      "type": "bargauge",
      "title": "Reconciliation discrepancies by type",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_discrepancies{partner=\"$partner\"}", "legendFormat": "{{type}}", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"displayMode": "gradient", "orientation": "horizontal", "showUnfilled": true},
      "gridPos": {"h": 10, "w": 6, "x": 18, "y": 7}
    },
    {
      "type": "stat",
      "title": "Usage ledger amount",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_ledger_amount{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 6, "x": 0, "y": 17}
    },
    {
      "type": "stat",
      "title": "Settlement amount",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_settlement_amount{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "currencyBRL", "decimals": 2}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 6, "x": 6, "y": 17}
    },
    {
      "type": "stat",
      "title": "Usage ledger records",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_ledger_records{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 6, "x": 12, "y": 17}
    },
    {
      "type": "stat",
      "title": "Settlement records",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"expr": "telco_commercial_reconciliation_settlement_records{partner=\"$partner\"}", "refId": "A"}],
      "fieldConfig": {"defaults": {"decimals": 0}, "overrides": []},
      "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "textMode": "auto"},
      "gridPos": {"h": 7, "w": 6, "x": 18, "y": 17}
    },
    {
      "type": "table",
      "title": "Commercial usage by meter and outcome",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{
        "expr": "sum by (meter, outcome) (telco_commercial_usage_requests_total{partner=\"$partner\"})",
        "format": "table",
        "instant": true,
        "refId": "A"
      }],
      "options": {"showHeader": true},
      "gridPos": {"h": 9, "w": 12, "x": 0, "y": 24}
    },
    {
      "type": "table",
      "title": "Billed amount by meter",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{
        "expr": "sum by (meter, currency) (telco_commercial_billed_amount_total{partner=\"$partner\"})",
        "format": "table",
        "instant": true,
        "refId": "A"
      }],
      "options": {"showHeader": true},
      "gridPos": {"h": 9, "w": 12, "x": 12, "y": 24}
    }
  ],
  "refresh": "5s",
  "schemaVersion": 39,
  "tags": ["telco", "commercial", "prepaid", "reconciliation", "wso2"],
  "templating": {
    "list": [
      {
        "name": "partner",
        "label": "Prepaid partner",
        "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "query": {"query": "label_values(telco_prepaid_wallet_balance, partner)", "refId": "PrometheusVariableQueryEditor-VariableQuery"},
        "definition": "label_values(telco_prepaid_wallet_balance, partner)",
        "refresh": 1,
        "sort": 1,
        "multi": false,
        "includeAll": false,
        "current": {"selected": true, "text": "prepaid-fintech-br-001", "value": "prepaid-fintech-br-001"}
      }
    ]
  },
  "time": {"from": "now-30m", "to": "now"},
  "timezone": "browser",
  "title": "Prepaid Wallet & Commercial Reconciliation",
  "uid": "prepaid-wallet-reconciliation",
  "version": 1
}
JSON

cat > "$GRAFANA_VERIFY" <<'VERIFY'
#!/usr/bin/env bash
set -Eeuo pipefail

STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
PARTNER="${PREPAID_PARTNER_ID:-prepaid-fintech-br-001}"

pass() { printf '[prepaid-grafana][PASS] %s\n' "$*"; }
fail() { printf '[prepaid-grafana][FAIL] %s\n' "$*" >&2; exit 1; }

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required."
done

metrics="$(curl -fsS "$STORE_URL/metrics")" || fail "Commercial metrics endpoint is unavailable."
for metric in \
  telco_prepaid_wallet_balance \
  telco_prepaid_wallet_topup_amount_total \
  telco_prepaid_wallet_debited_amount_total \
  telco_prepaid_credit_denials_total \
  telco_commercial_reconciliation_reconciled \
  telco_commercial_reconciliation_discrepancies
 do
  grep -Fq "$metric" <<<"$metrics" || fail "Metric is missing: $metric"
done
pass "Commercial meter store exposes prepaid and reconciliation metrics"

query_value() {
  local query="$1"
  curl -fsS --get \
    --data-urlencode "query=$query" \
    "$PROMETHEUS_URL/api/v1/query" |
    jq -r '.data.result[0].value[1] // empty'
}

for _ in $(seq 1 30); do
  balance="$(query_value "telco_prepaid_wallet_balance{partner=\"$PARTNER\"}")"
  [[ -n "$balance" ]] && break
  sleep 2
done
[[ -n "${balance:-}" ]] || fail "Prometheus has not scraped the prepaid wallet metrics."
pass "Prometheus is scraping the prepaid wallet metrics"

jq -ne --argjson value "$balance" '($value - 0.12 | if . < 0 then -. else . end) < 0.000001' >/dev/null \
  || fail "Expected final prepaid balance 0.12, found $balance"
pass "Grafana source data contains the final BRL 0.12 wallet balance"

denials="$(query_value "sum(telco_prepaid_credit_denials_total{partner=\"$PARTNER\"})")"
jq -ne --argjson value "${denials:-0}" '$value >= 1' >/dev/null \
  || fail "Expected at least one prepaid credit denial, found ${denials:-0}"
pass "Grafana source data proves the credit-exhaustion rejection"

reconciled="$(query_value "telco_commercial_reconciliation_reconciled{partner=\"$PARTNER\"}")"
[[ "$reconciled" == "1" ]] || fail "Expected reconciled=1, found ${reconciled:-missing}"
pass "Grafana source data reports a clean final reconciliation"

for _ in $(seq 1 30); do
  dashboard="$(curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$GRAFANA_URL/api/dashboards/uid/prepaid-wallet-reconciliation" 2>/dev/null || true)"
  [[ "$(jq -r '.dashboard.uid // empty' <<<"$dashboard" 2>/dev/null)" == "prepaid-wallet-reconciliation" ]] && break
  sleep 2
done
[[ "$(jq -r '.dashboard.uid // empty' <<<"${dashboard:-{}}" 2>/dev/null)" == "prepaid-wallet-reconciliation" ]] \
  || fail "Grafana did not provision the prepaid wallet dashboard."
pass "Grafana provisioned Prepaid Wallet & Commercial Reconciliation"
VERIFY

chmod +x "$GRAFANA_VERIFY"

node --check "$EXT_JS"
node --check "$SERVER_JS"
python3 -m json.tool "$DASHBOARD_JSON" >/dev/null
bash -n "$RESET_SCRIPT" "$GRAFANA_VERIFY"
[[ ! -f "$WIRING_VERIFY" ]] || bash -n "$WIRING_VERIFY"

grep -Fq 'commercial-meter-store-primary:8086' "$PROMETHEUS_YML" \
  || fail "Prometheus scrape target was not installed."
grep -Fq 'telco_prepaid_wallet_balance' "$EXT_JS" \
  || fail "Wallet metrics were not installed."
grep -Fq 'verify-prepaid-grafana.sh' "$RESET_SCRIPT" \
  || fail "The AI reset was not wired to Grafana verification."

ROLLBACK="$BACKUP_DIR/rollback.sh"
cat > "$ROLLBACK" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$ROOT_DIR"
cp "$BACKUP_DIR/$EXT_JS" "$EXT_JS"
cp "$BACKUP_DIR/$SERVER_JS" "$SERVER_JS"
cp "$BACKUP_DIR/$PROMETHEUS_YML" "$PROMETHEUS_YML"
cp "$BACKUP_DIR/$RESET_SCRIPT" "$RESET_SCRIPT"
if [[ -f "$BACKUP_DIR/$DASHBOARD_JSON" ]]; then cp "$BACKUP_DIR/$DASHBOARD_JSON" "$DASHBOARD_JSON"; else rm -f "$DASHBOARD_JSON"; fi
if [[ -f "$BACKUP_DIR/$GRAFANA_VERIFY" ]]; then cp "$BACKUP_DIR/$GRAFANA_VERIFY" "$GRAFANA_VERIFY"; else rm -f "$GRAFANA_VERIFY"; fi
if [[ -f "$BACKUP_DIR/$WIRING_VERIFY" ]]; then cp "$BACKUP_DIR/$WIRING_VERIFY" "$WIRING_VERIFY"; fi
printf '[rollback][PASS] Restored files from %s\n' "$BACKUP_DIR"
ROLLBACK
chmod +x "$ROLLBACK"

ok "Prepaid wallet and reconciliation metrics installed."
ok "Prometheus now scrapes only the primary shared-state meter store."
ok "Grafana dashboard created: Prepaid Wallet & Commercial Reconciliation."
ok "reset-with-telco-ai.sh now validates the Grafana dashboard."
printf '\nRollback: bash %s\n' "$ROLLBACK"

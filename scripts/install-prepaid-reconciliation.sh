#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$(pwd)}"
cd "$ROOT_DIR"

SERVER_JS="services/commercial-meter-store/src/server.js"
EXT_JS="services/commercial-meter-store/src/prepaid-commercial-extension.js"
COMMERCIAL_API="services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml"
PREAUTH_SEQUENCE="services/wso2-mi/synapse-configs/default/sequences/CommercialPrepaidPreAuthorizationSequence.xml"
VERIFY_SCRIPT="scripts/verify-prepaid-reconciliation.sh"
DEMO_SCRIPT="scripts/demo-prepaid-reconciliation.sh"

fail() { printf '[install-prepaid][FAIL] %s\n' "$*" >&2; exit 1; }
ok() { printf '[install-prepaid][OK] %s\n' "$*"; }

[[ -f docker-compose.yml ]] || fail "Run this from the repository root: $ROOT_DIR"
for file in "$SERVER_JS" "$COMMERCIAL_API"; do [[ -f "$file" ]] || fail "Missing $file"; done
for command in python3 node; do command -v "$command" >/dev/null 2>&1 || fail "$command is required"; done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/$STAMP"
for file in "$SERVER_JS" "$COMMERCIAL_API"; do
  mkdir -p "$BACKUP_DIR/$(dirname "$file")"
  cp "$file" "$BACKUP_DIR/$file"
done
for file in "$EXT_JS" "$PREAUTH_SEQUENCE" "$VERIFY_SCRIPT" "$DEMO_SCRIPT"; do
  if [[ -f "$file" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
    cp "$file" "$BACKUP_DIR/$file"
  else
    printf '%s\n' "$file" >> "$BACKUP_DIR/created-files.txt"
  fi
done
ok "Backup created at $BACKUP_DIR"

cat > "$EXT_JS" <<'JS'
'use strict';

const crypto = require('node:crypto');

function money(value) {
  return Number(Number(value || 0).toFixed(6));
}

function ensureState(state) {
  let changed = false;
  if (!state.wallets) { state.wallets = {}; changed = true; }
  if (!state.settlementRecords) { state.settlementRecords = {}; changed = true; }
  if (Number(state.version || 1) < 2) { state.version = 2; changed = true; }
  for (const assignment of Object.values(state.assignments || {})) {
    if (!assignment.billingMode) { assignment.billingMode = 'POSTPAID'; changed = true; }
  }
  return changed;
}

function ensureWallet(state, partnerId, currency = 'BRL') {
  ensureState(state);
  if (!state.wallets[partnerId]) {
    state.wallets[partnerId] = {
      partnerId,
      currency: String(currency).toUpperCase(),
      balance: 0,
      transactions: [],
      updatedAt: new Date().toISOString()
    };
  }
  return state.wallets[partnerId];
}

function quoteCharge({ state, partnerId, meter, PLAN_CATALOG, PRODUCT, aggregateUsage }) {
  ensureState(state);
  const assignment = state.assignments[partnerId];
  if (!assignment) {
    throw Object.assign(new Error(`No commercial plan is assigned to ${partnerId}.`), {
      status: 404,
      code: 'PARTNER_PLAN_NOT_FOUND'
    });
  }
  const plan = PLAN_CATALOG[assignment.planId];
  const usage = aggregateUsage(state, partnerId, PRODUCT);
  const prices = plan?.prices?.[meter];
  if (!prices) {
    throw Object.assign(new Error(`Unknown commercial meter ${meter}.`), {
      status: 400,
      code: 'UNKNOWN_COMMERCIAL_METER'
    });
  }

  let quotedAmount = 0;
  if (assignment.planId === 'Business') {
    quotedAmount = usage.overLimit ? prices.overage : prices.included;
  } else if (assignment.planId === 'Enterprise') {
    quotedAmount = usage.overLimit ? prices.overage : prices.committed;
  }
  return { assignment, quotedAmount: money(quotedAmount) };
}

function applyPrepaidDebit(state, event) {
  ensureState(state);
  const assignment = state.assignments[event.partnerId];
  if (!assignment || assignment.billingMode !== 'PREPAID') return null;

  const wallet = ensureWallet(state, event.partnerId, assignment.currency || event.currency);
  const existing = wallet.transactions.find(
    (transaction) => transaction.type === 'DEBIT' && transaction.reference === event.eventId
  );
  if (existing) return existing;

  const amount = money(event.billedAmount);
  if (amount <= 0) return null;
  if (money(wallet.balance) < amount) {
    throw Object.assign(
      new Error(
        `Insufficient prepaid credit. Required ${amount.toFixed(2)} ${wallet.currency}; ` +
        `available ${money(wallet.balance).toFixed(2)}.`
      ),
      { status: 402, code: 'PREPAID_CREDIT_EXHAUSTED' }
    );
  }

  const balanceBefore = money(wallet.balance);
  const transaction = {
    transactionId: `debit-${event.eventId}`,
    type: 'DEBIT',
    reference: event.eventId,
    eventId: event.eventId,
    meter: event.meter,
    amount,
    currency: wallet.currency,
    balanceBefore,
    balanceAfter: money(balanceBefore - amount),
    occurredAt: new Date().toISOString()
  };
  wallet.balance = transaction.balanceAfter;
  wallet.updatedAt = transaction.occurredAt;
  wallet.transactions.push(transaction);
  return transaction;
}

function buildReconciliation(state, partnerId) {
  ensureState(state);
  const events = (state.events || []).filter(
    (event) => event.partnerId === partnerId && money(event.billedAmount) > 0
  );
  const records = Object.values(state.settlementRecords).filter(
    (record) => record.partnerId === partnerId
  );
  const byEvent = new Map(records.map((record) => [record.eventId, record]));
  const eventIds = new Set(events.map((event) => event.eventId));
  const discrepancies = [];

  for (const event of events) {
    const record = byEvent.get(event.eventId);
    if (!record) {
      discrepancies.push({
        type: 'MISSING_SETTLEMENT_RECORD', eventId: event.eventId,
        expectedAmount: money(event.billedAmount), actualAmount: null, currency: event.currency
      });
    } else if (money(record.amount) !== money(event.billedAmount) || record.currency !== event.currency) {
      discrepancies.push({
        type: 'AMOUNT_MISMATCH', eventId: event.eventId,
        expectedAmount: money(event.billedAmount), actualAmount: money(record.amount),
        expectedCurrency: event.currency, actualCurrency: record.currency
      });
    }
  }
  for (const record of records) {
    if (!eventIds.has(record.eventId)) {
      discrepancies.push({
        type: 'ORPHAN_SETTLEMENT_RECORD', eventId: record.eventId,
        expectedAmount: null, actualAmount: money(record.amount), currency: record.currency
      });
    }
  }

  return {
    partnerId,
    ledger: {
      records: events.length,
      totalAmount: money(events.reduce((sum, event) => sum + money(event.billedAmount), 0))
    },
    settlement: {
      records: records.length,
      totalAmount: money(records.reduce((sum, record) => sum + money(record.amount), 0))
    },
    discrepancyCount: discrepancies.length,
    reconciled: discrepancies.length === 0,
    discrepancies,
    generatedAt: new Date().toISOString()
  };
}

async function handleRequest(ctx) {
  const {
    req, res, url, correlationId, readJson, readState, writeState,
    PLAN_CATALOG, PRODUCT, aggregateUsage, json, problem, logEvent
  } = ctx;

  if (req.method === 'POST' && url.pathname === '/preauthorizations') {
    const body = await readJson(req);
    const partnerId = String(body.partnerId || '');
    const meter = String(body.meter || '');
    if (!partnerId || !meter) {
      problem(res, 400, 'PREAUTHORIZATION_CONTEXT_REQUIRED', 'partnerId and meter are required.', correlationId);
      return true;
    }
    const state = readState();
    const quote = quoteCharge({ state, partnerId, meter, PLAN_CATALOG, PRODUCT, aggregateUsage });
    if (quote.assignment.billingMode !== 'PREPAID') {
      json(res, 200, {
        authorized: true,
        billingMode: quote.assignment.billingMode || 'POSTPAID',
        quotedAmount: quote.quotedAmount,
        creditCheckRequired: false,
        correlationId
      });
      return true;
    }
    const wallet = ensureWallet(state, partnerId, quote.assignment.currency);
    writeState(state);
    const authorized = money(wallet.balance) >= quote.quotedAmount;
    json(res, 200, {
      authorized,
      billingMode: 'PREPAID',
      partnerId,
      meter,
      quotedAmount: quote.quotedAmount,
      balance: money(wallet.balance),
      currency: wallet.currency,
      creditCheckRequired: true,
      reason: authorized ? null : 'PREPAID_CREDIT_EXHAUSTED',
      correlationId
    });
    return true;
  }

  let match = url.pathname.match(/^\/wallets\/([^/]+)$/);
  if (match && req.method === 'GET') {
    const partnerId = decodeURIComponent(match[1]);
    const state = readState();
    ensureState(state);
    const assignment = state.assignments[partnerId];
    if (!assignment) {
      problem(res, 404, 'PARTNER_PLAN_NOT_FOUND', `No commercial plan is assigned to ${partnerId}.`, correlationId);
      return true;
    }
    const wallet = ensureWallet(state, partnerId, assignment.currency);
    writeState(state);
    json(res, 200, { wallet, assignment, correlationId });
    return true;
  }

  match = url.pathname.match(/^\/wallets\/([^/]+)\/topups$/);
  if (match && req.method === 'POST') {
    const partnerId = decodeURIComponent(match[1]);
    const body = await readJson(req);
    const amount = money(body.amount);
    const reference = String(body.reference || '');
    if (amount <= 0 || !reference) {
      problem(res, 400, 'INVALID_TOPUP', 'A positive amount and an idempotency reference are required.', correlationId);
      return true;
    }
    const state = readState();
    ensureState(state);
    const assignment = state.assignments[partnerId];
    if (!assignment) {
      problem(res, 404, 'PARTNER_PLAN_NOT_FOUND', `No commercial plan is assigned to ${partnerId}.`, correlationId);
      return true;
    }
    if (assignment.billingMode !== 'PREPAID') {
      problem(res, 409, 'PARTNER_NOT_PREPAID', `${partnerId} is not configured for prepaid settlement.`, correlationId);
      return true;
    }
    const wallet = ensureWallet(state, partnerId, assignment.currency);
    const existing = wallet.transactions.find(
      (transaction) => transaction.type === 'TOPUP' && transaction.reference === reference
    );
    if (existing) {
      json(res, 200, { idempotentReplay: true, transaction: existing, wallet, correlationId });
      return true;
    }
    const balanceBefore = money(wallet.balance);
    const transaction = {
      transactionId: `topup-${crypto.randomUUID()}`,
      type: 'TOPUP', reference, amount, currency: wallet.currency,
      balanceBefore, balanceAfter: money(balanceBefore + amount),
      occurredAt: new Date().toISOString()
    };
    wallet.balance = transaction.balanceAfter;
    wallet.updatedAt = transaction.occurredAt;
    wallet.transactions.push(transaction);
    writeState(state);
    logEvent('prepaid-topup', { correlationId, partnerId, reference, amount, balanceAfter: wallet.balance });
    json(res, 201, { idempotentReplay: false, transaction, wallet, correlationId });
    return true;
  }

  match = url.pathname.match(/^\/settlement-records\/([^/]+)$/);
  if (match && req.method === 'PUT') {
    const eventId = decodeURIComponent(match[1]);
    const body = await readJson(req);
    const partnerId = String(body.partnerId || '');
    if (!partnerId) {
      problem(res, 400, 'PARTNER_ID_REQUIRED', 'partnerId is required.', correlationId);
      return true;
    }
    const state = readState();
    ensureState(state);
    const existed = Boolean(state.settlementRecords[eventId]);
    const record = {
      eventId, partnerId, amount: money(body.amount),
      currency: String(body.currency || 'BRL').toUpperCase(),
      recordType: String(body.recordType || 'PREPAID_DEBIT'),
      source: String(body.source || 'mock-settlement-platform'),
      receivedAt: new Date().toISOString()
    };
    state.settlementRecords[eventId] = record;
    writeState(state);
    json(res, existed ? 200 : 201, { created: !existed, updated: existed, record, correlationId });
    return true;
  }

  if (req.method === 'GET' && url.pathname === '/reconciliation') {
    const partnerId = url.searchParams.get('partnerId');
    if (!partnerId) {
      problem(res, 400, 'PARTNER_ID_REQUIRED', 'partnerId is required.', correlationId);
      return true;
    }
    json(res, 200, { ...buildReconciliation(readState(), partnerId), correlationId });
    return true;
  }

  if (req.method === 'POST' && url.pathname === '/reconciliation/replay') {
    const body = await readJson(req);
    const eventId = String(body.eventId || '');
    const state = readState();
    ensureState(state);
    const event = (state.events || []).find((candidate) => candidate.eventId === eventId);
    if (!event) {
      problem(res, 404, 'USAGE_EVENT_NOT_FOUND', `Usage event ${eventId} does not exist.`, correlationId);
      return true;
    }
    const previous = state.settlementRecords[eventId] || null;
    const record = {
      eventId, partnerId: event.partnerId, amount: money(event.billedAmount), currency: event.currency,
      recordType: 'PREPAID_DEBIT', source: 'reconciliation-replay', receivedAt: new Date().toISOString()
    };
    state.settlementRecords[eventId] = record;
    writeState(state);
    logEvent('settlement-replayed', { correlationId, eventId, partnerId: event.partnerId, corrected: Boolean(previous) });
    json(res, 200, {
      replayed: true, corrected: Boolean(previous), previous, record,
      reconciliation: buildReconciliation(state, event.partnerId), correlationId
    });
    return true;
  }

  match = url.pathname.match(/^\/demo\/partners\/([^/]+)\/reset$/);
  if (match && req.method === 'POST') {
    const partnerId = decodeURIComponent(match[1]);
    const state = readState();
    ensureState(state);
    delete state.assignments[partnerId];
    delete state.wallets[partnerId];
    state.events = (state.events || []).filter((event) => event.partnerId !== partnerId);
    for (const key of Object.keys(state.seedUsage || {})) {
      if (state.seedUsage[key].partnerId === partnerId) delete state.seedUsage[key];
    }
    for (const [eventId, record] of Object.entries(state.settlementRecords)) {
      if (record.partnerId === partnerId) delete state.settlementRecords[eventId];
    }
    writeState(state);
    logEvent('partner-demo-reset', { correlationId, partnerId });
    json(res, 200, { reset: true, partnerId, correlationId });
    return true;
  }

  return false;
}

module.exports = { applyPrepaidDebit, handleRequest };
JS
ok "Created isolated extension: $EXT_JS"

python3 - "$SERVER_JS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()

import_line = "const prepaidCommercial = require('./prepaid-commercial-extension');"
if import_line not in s:
    marker = "const crypto = require('node:crypto');"
    if marker not in s:
        raise SystemExit(f'Could not find {marker}')
    s = s.replace(marker, marker + "\n" + import_line, 1)

start = s.find('function normalizedAssignment(')
end = s.find('function aggregateUsage(', start)
if start < 0 or end < 0:
    raise SystemExit('Could not locate normalizedAssignment')
normalized = '''function normalizedAssignment(partnerId, input = {}) {
  const planId = input.planId || 'Sandbox';
  const plan = PLAN_CATALOG[planId];
  if (!plan) throw Object.assign(new Error(`unknown planId ${planId}`), { status: 400, code: 'UNKNOWN_COMMERCIAL_PLAN' });
  const billingMode = String(input.billingMode || 'POSTPAID').toUpperCase();
  if (!['POSTPAID', 'PREPAID'].includes(billingMode)) {
    throw Object.assign(new Error(`unsupported billingMode ${billingMode}`), { status: 400, code: 'INVALID_BILLING_MODE' });
  }
  return {
    partnerId,
    apiProduct: PRODUCT,
    planId,
    billingMode,
    country: String(input.country || plan.country).toUpperCase(),
    currency: String(input.currency || plan.currency).toUpperCase(),
    effectiveFrom: input.effectiveFrom || new Date().toISOString(),
    contractReference: input.contractReference || `DEMO-${partnerId}-${planId}`,
    assignedBy: input.assignedBy || 'commercial-bootstrap',
    updatedAt: new Date().toISOString()
  };
}

'''
s = s[:start] + normalized + s[end:]

handler = '''  if (await prepaidCommercial.handleRequest({
    req, res, url, correlationId, readJson, readState, writeState,
    PLAN_CATALOG, PRODUCT, aggregateUsage, json, problem, logEvent
  })) return;

'''
if 'prepaidCommercial.handleRequest' not in s:
    marker = '  const capabilityMatch ='
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit(f'Could not find {marker}')
    s = s[:pos] + handler + s[pos:]

if 'prepaidCommercial.applyPrepaidDebit' not in s:
    marker = 'state.events.push(persisted);'
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit(f'Could not find {marker}')
    line_start = s.rfind('\n', 0, pos) + 1
    indent = s[line_start:pos]
    s = s[:line_start] + indent + 'prepaidCommercial.applyPrepaidDebit(state, persisted);\n' + s[line_start:]

old = "return problem(res, status, status === 500 ? 'INTERNAL_ERROR' : 'INVALID_REQUEST', error.message, correlationId);"
new = "const code = error.code || (status === 500 ? 'INTERNAL_ERROR' : 'INVALID_REQUEST');\n    return problem(res, status, code, error.message, correlationId);"
if old in s:
    s = s.replace(old, new, 1)
elif 'const code = error.code ||' not in s:
    raise SystemExit('Could not patch request-handler error code preservation')

path.write_text(s)
PY
ok "Patched $SERVER_JS with four isolated integration hooks"

cat > "$PREAUTH_SEQUENCE" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse"
          name="CommercialPrepaidPreAuthorizationSequence"
          trace="disable">
    <sequence key="CommercialCorrelationSequence"/>
    <enrich>
        <source clone="true" type="body"/>
        <target action="replace" property="commercial.prepaid.originalPayload" type="property"/>
    </enrich>
    <property name="commercial.prepaid.partnerId"
              expression="json-eval($.partnerId)"
              scope="default"
              type="STRING"/>
    <filter source="get-property('commercial.prepaid.partnerId')" regex=".+">
        <then>
            <payloadFactory media-type="json">
                <format>{"partnerId":"$1","meter":"$2"}</format>
                <args>
                    <arg evaluator="xml" expression="get-property('commercial.prepaid.partnerId')"/>
                    <arg evaluator="xml" expression="get-property('commercial.meter')"/>
                </args>
            </payloadFactory>
            <property name="REST_URL_POSTFIX" value="/preauthorizations" scope="axis2" type="STRING"/>
            <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <header name="X-Correlation-ID"
                    expression="get-property('commercial.correlationId')"
                    scope="transport"/>
            <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
            <property name="commercial.prepaid.authorized"
                      expression="json-eval($.authorized)" scope="default" type="STRING"/>
            <property name="commercial.prepaid.quotedAmount"
                      expression="json-eval($.quotedAmount)" scope="default" type="STRING"/>
            <property name="commercial.prepaid.balance"
                      expression="json-eval($.balance)" scope="default" type="STRING"/>
            <property name="commercial.prepaid.currency"
                      expression="json-eval($.currency)" scope="default" type="STRING"/>
            <filter source="get-property('commercial.prepaid.authorized')" regex="false">
                <then>
                    <payloadFactory media-type="json">
                        <format>{"type":"https://example.telco/errors/prepaid-credit-exhausted","title":"Prepaid credit exhausted","status":402,"code":"PREPAID_CREDIT_EXHAUSTED","detail":"The partner does not have sufficient prepaid credit for this operation.","partnerId":"$1","meter":"$2","requiredAmount":$3,"availableBalance":$4,"currency":"$5","correlationId":"$6"}</format>
                        <args>
                            <arg evaluator="xml" expression="get-property('commercial.prepaid.partnerId')"/>
                            <arg evaluator="xml" expression="get-property('commercial.meter')"/>
                            <arg evaluator="xml" expression="get-property('commercial.prepaid.quotedAmount')"/>
                            <arg evaluator="xml" expression="get-property('commercial.prepaid.balance')"/>
                            <arg evaluator="xml" expression="get-property('commercial.prepaid.currency')"/>
                            <arg evaluator="xml" expression="get-property('commercial.correlationId')"/>
                        </args>
                    </payloadFactory>
                    <property name="HTTP_SC" value="402" scope="axis2" type="STRING"/>
                    <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <header name="X-Correlation-ID"
                            expression="get-property('commercial.correlationId')"
                            scope="transport"/>
                    <respond/>
                </then>
            </filter>
        </then>
    </filter>
    <enrich>
        <source clone="true" property="commercial.prepaid.originalPayload" type="property"/>
        <target action="replace" type="body"/>
    </enrich>
</sequence>
XML
ok "Created $PREAUTH_SEQUENCE"

python3 - "$COMMERCIAL_API" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
s = path.read_text()
preauth = '<sequence key="CommercialPrepaidPreAuthorizationSequence"/>'
execute = '<sequence key="CommercialExecuteTransactionSequence"/>'
if preauth not in s:
    count = s.count(execute)
    if count != 3:
        raise SystemExit(f'Expected 3 commercial transaction sequence calls, found {count}')
    s = s.replace(execute, preauth + '\n    ' + execute)
elif s.count(preauth) != 3:
    raise SystemExit('Prepaid preauthorization is only partially installed')
path.write_text(s)
PY
ok 'Added preauthorization before all three existing commercial operations'

cat > "$VERIFY_SCRIPT" <<'VERIFY'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
PARTNER="${PREPAID_PARTNER_ID:-prepaid-fintech-br-001}"
SHOW_JSON="${SHOW_JSON:-false}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prepaid-reconciliation.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

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
jq -e '.code == "PREPAID_CREDIT_EXHAUSTED" and .requiredAmount == 0.08 and .availableBalance == 0' "$WORK_DIR/exhausted.json" >/dev/null \
  || fail 'Exhaustion payload is incorrect'
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
VERIFY
chmod +x "$VERIFY_SCRIPT"

cat > "$DEMO_SCRIPT" <<'DEMO'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOW_JSON=true exec "$ROOT_DIR/scripts/verify-prepaid-reconciliation.sh" "$@"
DEMO
chmod +x "$DEMO_SCRIPT"
ok "Created verifier and live demo scripts"

ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
cat > "$ROLLBACK_SCRIPT" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(pwd)"
cp "$BACKUP_DIR/$SERVER_JS" "$SERVER_JS"
cp "$BACKUP_DIR/$COMMERCIAL_API" "$COMMERCIAL_API"
if [[ -f "$BACKUP_DIR/created-files.txt" ]]; then
  while IFS= read -r file; do rm -f "\$file"; done < "$BACKUP_DIR/created-files.txt"
fi
for file in "$EXT_JS" "$PREAUTH_SEQUENCE" "$VERIFY_SCRIPT" "$DEMO_SCRIPT"; do
  [[ -f "$BACKUP_DIR/\$file" ]] && { mkdir -p "\$(dirname "\$file")"; cp "$BACKUP_DIR/\$file" "\$file"; }
done
printf '[rollback][OK] Restored %s\n' "$BACKUP_DIR"
ROLLBACK
chmod +x "$ROLLBACK_SCRIPT"

node --check "$SERVER_JS"
node --check "$EXT_JS"
python3 - "$COMMERCIAL_API" "$PREAUTH_SEQUENCE" <<'PY'
from xml.etree import ElementTree as ET
import sys
for filename in sys.argv[1:]: ET.parse(filename)
PY
bash -n "$VERIFY_SCRIPT"
bash -n "$DEMO_SCRIPT"
[[ "$(grep -c 'CommercialPrepaidPreAuthorizationSequence' "$COMMERCIAL_API")" == 3 ]] \
  || fail 'Expected three preauthorization hooks'

ok 'Static validation completed'
printf '\nBackup: %s\nRollback: bash %s\n' "$BACKUP_DIR" "$ROLLBACK_SCRIPT"
printf '\nNext:\n'
printf '  docker compose -f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.opa.yml -f docker-compose.mi.yml -f docker-compose.commercial.yml -f docker-compose.mi.soap.yml -f docker-compose.observability.yml build commercial-meter-store-primary commercial-meter-store-secondary wso2-mi\n'
printf '  bash scripts/telco-demo-control.sh restart\n'
printf '  bash scripts/verify-commercial-plan-usage.sh\n'
printf '  bash scripts/verify-prepaid-reconciliation.sh\n'

'use strict';

const crypto = require('node:crypto');

function money(value) {
  return Number(Number(value || 0).toFixed(6));
}

function ensureState(state) {
  let changed = false;
  if (!state.wallets) { state.wallets = {}; changed = true; }
  if (!state.settlementRecords) { state.settlementRecords = {}; changed = true; }
  if (!state.prepaidCreditDenials) { state.prepaidCreditDenials = {}; changed = true; }
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
    for (const [denialKey, denial] of Object.entries(state.prepaidCreditDenials)) {
      if (denial.partnerId === partnerId) delete state.prepaidCreditDenials[denialKey];
    }
    writeState(state);
    logEvent('partner-demo-reset', { correlationId, partnerId });
    json(res, 200, { reset: true, partnerId, correlationId });
    return true;
  }

  return false;
}

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

module.exports = { applyPrepaidDebit, handleRequest, appendPrometheusMetrics };

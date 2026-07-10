const backend = window.PORTAL_CONFIG.backendUrl;
const pipeline = window.PORTAL_CONFIG.pipelineUrl;

const qs = selector => document.querySelector(selector);
const qsa = selector => [...document.querySelectorAll(selector)];
const fmt = new Intl.NumberFormat('en-US');
const money = n => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(Number(n || 0));

const state = {
  metadata: null,
  currentCustomer: '+525512340001',
  eventCount: 0,
  eventSource: null
};

const pageCopy = {
  overview: {
    title: 'Executive overview',
    subtitle: 'Business, network and partner API capabilities governed through WSO2 API Manager.'
  },
  customer: {
    title: 'Customer & BSS',
    subtitle: 'Consent-aware customer, subscriber and eligibility APIs for partner and care journeys.'
  },
  network: {
    title: 'Network APIs',
    subtitle: 'Network slicing, quality-on-demand and OSS telemetry as monetizable API products.'
  },
  commercial: {
    title: 'Products & monetization',
    subtitle: 'API packaging, plans, quota, usage analytics and partner settlement views.'
  },
  runtime: {
    title: 'Streaming & legacy',
    subtitle: 'Event-driven APIs and SOAP modernization under the same API governance model.'
  }
};

async function getJson(path) {
  const res = await fetch(`${backend}${path}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

async function postJson(path, body) {
  const res = await fetch(`${backend}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

function setTab(tab) {
  qsa('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.tab === tab));
  qsa('.tab-panel').forEach(panel => panel.classList.toggle('active', panel.id === `tab-${tab}`));
  qs('#pageTitle').textContent = pageCopy[tab].title;
  qs('#pageSubtitle').textContent = pageCopy[tab].subtitle;
}

function tag(value, tone = '') {
  return `<span class="pill ${tone}">${value}</span>`;
}

function compactNumber(value) {
  return new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 }).format(value);
}

async function init() {
  wireEvents();
  qs('#pipelineLink').href = pipeline;

  const health = await getJson('/health');
  qs('#backendStatus').textContent = health.ok ? 'Backend online' : 'Backend offline';
  qs('#backendProtocols').textContent = health.protocols.join(' · ');

  state.metadata = await getJson('/metadata');
  renderMetadata(state.metadata);

  await Promise.all([
    refreshCustomer(),
    refreshSlices(),
    refreshUsage(),
    refreshCell(),
    refreshSettlement()
  ]);

  connectEvents();
}

function renderMetadata(metadata) {
  qs('#marketsCount').textContent = metadata.countries.length;
  qs('#productsCount').textContent = (metadata.apiProductBundles || metadata.apiProducts).length;

  qs('#marketsTable').innerHTML = `
    <table>
      <thead><tr><th>Market</th><th>Region</th><th>Subscribers</th><th>Currency</th></tr></thead>
      <tbody>
        ${metadata.countries.map(c => `<tr><td><strong>${c.code}</strong> ${c.name}</td><td>${c.region}</td><td>${compactNumber(c.subscribers)}</td><td>${c.currency}</td></tr>`).join('')}
      </tbody>
    </table>
  `;

  qs('#customerSelect').innerHTML = [
    ['+525512340001', 'MX · Postpaid Premium'],
    ['+551199990001', 'BR · Postpaid Consumer'],
    ['+573001230001', 'CO · Enterprise IoT']
  ].map(([value, label]) => `<option value="${value}">${label}</option>`).join('');

  qs('#partnerSelect').innerHTML = metadata.partners.map(p => `<option value="${p.id}">${p.name} · ${p.segment}</option>`).join('');

  qs('#products').innerHTML = (metadata.apiProductBundles || metadata.apiProducts).map(product => `
    <article class="product-card">
      <div class="product-topline">
        <strong>${product.name}</strong>
        ${tag(product.plan, 'blue')}
      </div>
      <p>${product.description}</p>
      <div class="mini-label">APIs</div>
      <div class="chip-row">${product.apis.map(api => `<span>${api}</span>`).join('')}</div>
      <div class="mini-label">Markets</div>
      <small>${product.markets.join(' · ')}</small>
    </article>
  `).join('');

  qs('#plans').innerHTML = metadata.monetizationPlans.map(plan => `
    <article class="price-card">
      <div class="product-topline"><strong>${plan.name}</strong><span>${plan.price ? money(plan.price) + '/mo' : 'Free'}</span></div>
      <p>${plan.target}</p>
      <small>${plan.quota}</small>
      <small>Overage: ${plan.overage ? `$${plan.overage}/call` : 'none'}</small>
    </article>
  `).join('');
}

async function refreshCustomer() {
  const selected = qs('#customerSelect')?.value || state.currentCustomer;
  state.currentCustomer = selected;

  const msisdn = encodeURIComponent(selected);
  const data = await getJson(`/api/v1/customers/${msisdn}/profile`);
  const consent = await getJson(`/api/v1/customers/${msisdn}/consent`);

  qs('#customerBox').innerHTML = `
    <div><small>Subscriber</small><strong>${data.customer.name}</strong><span>${data.customer.msisdn}</span></div>
    <div><small>Market</small><strong>${data.customer.country}</strong><span>${data.customer.segment}</span></div>
    <div><small>Lifecycle</small><strong>${data.customer.lifecycle}</strong><span>${data.customer.plan}</span></div>
    <div><small>Network</small><strong>${data.customer.network.rat}</strong><span>${data.customer.network.cellId}</span></div>
    <div><small>ARPU</small><strong>${money(data.customer.arpu)}</strong><span>monthly estimate</span></div>
    <div><small>Risk score</small><strong>${data.customer.riskScore}</strong><span>${data.customer.riskScore < 20 ? 'Low' : 'Review'}</span></div>
  `;

  qs('#consentBox').innerHTML = Object.entries(consent.consent).map(([key, value]) => tag(`${key}: ${value ? 'allowed' : 'blocked'}`, value ? 'green' : 'red')).join('');
  qs('#customerJson').textContent = JSON.stringify(data, null, 2);
}

async function checkEligibility() {
  const msisdn = encodeURIComponent(state.currentCustomer);
  const data = await getJson(`/api/v1/subscribers/${msisdn}/eligibility?product=5g-sa-premium`);
  qs('#eligibilityResult').className = `result-card ${data.eligible ? 'success' : 'warning'}`;
  qs('#eligibilityResult').innerHTML = `
    <strong>${data.eligible ? 'Eligible' : 'Not eligible'}</strong>
    <p>${data.reason}</p>
    <dl>
      <div><dt>Product</dt><dd>${data.product}</dd></div>
      <div><dt>Radio access</dt><dd>${data.network.rat}</dd></div>
      <div><dt>Serving cell</dt><dd>${data.network.cellId}</dd></div>
    </dl>
  `;
}

async function refreshSlices() {
  const data = await getJson('/api/v1/network/slices');
  qs('#slices').innerHTML = data.slices.map(slice => `
    <article class="slice-card">
      <div class="product-topline"><strong>${slice.id}</strong>${tag(slice.status, slice.status === 'AVAILABLE' ? 'green' : 'blue')}</div>
      <div class="metric-row"><span>Latency</span><strong>${slice.maxLatencyMs}ms</strong></div>
      <div class="metric-row"><span>Throughput</span><strong>${slice.maxThroughputMbps} Mbps</strong></div>
      <small>${slice.monetizationPlan}</small>
    </article>
  `).join('');
}

async function reserveSlice() {
  const data = await postJson('/api/v1/network/slices/reservations', {
    sliceId: 'urllc-qod-gold',
    country: 'BR',
    partnerId: 'ride-hailing',
    durationMinutes: 120,
    maxLatencyMs: 12
  });
  qs('#sliceResult').textContent = JSON.stringify(data, null, 2);
}

async function refreshCell() {
  const cellIds = ['BR-SP-5G-0097', 'MX-MEX-5G-0042', 'CO-BOG-LTE-0219'];
  const cellId = cellIds[Math.floor(Math.random() * cellIds.length)];
  const data = await getJson(`/api/v1/network/cells/${cellId}/status`);
  const tone = data.status === 'GREEN' ? 'success' : data.status === 'AMBER' ? 'warning' : 'danger';
  qs('#cellStatus').className = `result-card ${tone}`;
  qs('#cellStatus').innerHTML = `
    <strong>${data.cellId} · ${data.status}</strong>
    <p>${data.country} network cell telemetry</p>
    <dl>
      <div><dt>Utilization</dt><dd>${data.utilizationPct}%</dd></div>
      <div><dt>Avg latency</dt><dd>${data.avgLatencyMs}ms</dd></div>
      <div><dt>Active sessions</dt><dd>${fmt.format(data.activeSessions)}</dd></div>
    </dl>
  `;
}

async function refreshUsage() {
  const markets = ['MX', 'BR', 'CO', 'AR'];
  const results = await Promise.all(markets.map(m => getJson(`/api/v1/usage/summary?country=${m}`)));
  const totalCalls = results.reduce((sum, r) => sum + r.apiCalls, 0);
  const totalRevenue = results.reduce((sum, r) => sum + r.revenueUsd, 0);

  qs('#callsKpi').textContent = fmt.format(totalCalls);
  qs('#revenueKpi').textContent = money(totalRevenue);
  qs('#usageCards').innerHTML = results.map(r => `
    <article class="market-card">
      <div class="product-topline"><strong>${r.market}</strong><span>${money(r.revenueUsd)}</span></div>
      <div class="progress"><span style="width:${Math.min(100, r.errorRatePct * 40)}%"></span></div>
      <small>${fmt.format(r.apiCalls)} calls · ${fmt.format(r.billableCalls)} billable · ${r.errorRatePct}% errors</small>
      <p>${r.topProduct}</p>
    </article>
  `).join('');
}

async function refreshSettlement() {
  const partnerId = qs('#partnerSelect')?.value || 'banking-superapp';
  const data = await getJson(`/api/v1/partners/${partnerId}/settlement`);
  qs('#settlementResult').className = 'result-card success';
  qs('#settlementResult').innerHTML = `
    <strong>${data.partner.name}</strong>
    <p>${data.partner.segment} · ${data.partner.tier} · ${data.period}</p>
    <dl>
      <div><dt>Billable events</dt><dd>${fmt.format(data.billableEvents)}</dd></div>
      <div><dt>Gross revenue</dt><dd>${money(data.grossRevenueUsd)}</dd></div>
      <div><dt>Status</dt><dd>${data.settlementStatus}</dd></div>
      <div><dt>Invoice</dt><dd>${data.invoiceId}</dd></div>
    </dl>
  `;
}

async function callSoap() {
  const xml = `<?xml version="1.0"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:bil="http://demo.telco.wso2.com/billing"><soapenv:Header/><soapenv:Body><bil:CreateBillingAdjustmentRequest><msisdn>${state.currentCustomer}</msisdn><amount>12.40</amount><currency>USD</currency><reasonCode>ROAMING_CREDIT</reasonCode><requestor>care-agent-778</requestor></bil:CreateBillingAdjustmentRequest></soapenv:Body></soapenv:Envelope>`;
  const res = await fetch(`${backend}/soap/billing-adjustment`, { method: 'POST', headers: { 'content-type': 'text/xml' }, body: xml });
  qs('#soapResult').textContent = await res.text();
}

function connectEvents() {
  if (state.eventSource) state.eventSource.close();

  const source = new EventSource(`${backend}/events/network-events`);
  const container = qs('#eventStream');
  state.eventSource = source;

  source.onmessage = appendEvent;
  ['slice.utilization.high', 'qod.latency.breach', 'cell.congestion.warning', 'roaming.partner.degradation', 'charging.reconciliation.completed', 'connected'].forEach(type => source.addEventListener(type, appendEvent));

  function appendEvent(e) {
    let data;
    try {
      data = JSON.parse(e.data);
    } catch {
      return;
    }

    state.eventCount += 1;
    const div = document.createElement('article');
    div.className = `event-card ${data.severity || 'info'}`;
    div.innerHTML = `
      <div class="product-topline"><strong>${data.eventType || data.stream}</strong>${tag(data.severity || 'connected')}</div>
      <p>${data.market || data.country || 'Network stream'} ${data.cellId ? '· ' + data.cellId : ''}</p>
      <div class="event-metrics">
        <span>${data.utilizationPct ? data.utilizationPct + '% util.' : 'stream online'}</span>
        <span>${data.latencyMs ? data.latencyMs + 'ms' : 'live'}</span>
        <span>${data.monetizationImpactUsd ? money(data.monetizationImpactUsd) : 'no charge'}</span>
      </div>
      <small>${data.timestamp || new Date().toISOString()}</small>
    `;

    container.prepend(div);
    while (container.children.length > 12) container.lastChild.remove();
  }
}

function wireEvents() {
  qsa('.nav-item').forEach(button => button.addEventListener('click', () => setTab(button.dataset.tab)));
  qsa('[data-open-tab]').forEach(link => link.addEventListener('click', () => setTab(link.dataset.openTab)));

  qs('#customerSelect').addEventListener('change', refreshCustomer);
  qs('#refreshCustomer').addEventListener('click', refreshCustomer);
  qs('#checkEligibility').addEventListener('click', checkEligibility);
  qs('#refreshUsage').addEventListener('click', refreshUsage);
  qs('#reserveSlice').addEventListener('click', reserveSlice);
  qs('#refreshCell').addEventListener('click', refreshCell);
  qs('#refreshSettlement').addEventListener('click', refreshSettlement);
  qs('#partnerSelect').addEventListener('change', refreshSettlement);
  qs('#callSoap').addEventListener('click', callSoap);
}

init().catch(err => {
  console.error(err);
  qs('#backendStatus').textContent = `Portal error: ${err.message}`;
});

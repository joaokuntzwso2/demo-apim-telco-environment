(function () {
  const BACKEND = window.DEMO_CONFIG?.backendUrl || 'http://localhost:8081';

  function money(value) {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      maximumFractionDigits: 0
    }).format(value);
  }

  function compact(value) {
    return new Intl.NumberFormat('en-US', {
      notation: 'compact',
      maximumFractionDigits: 1
    }).format(value);
  }

  function writeJson(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  }

  async function fetchJson(path, options) {
    const res = await fetch(`${BACKEND}${path}`, options);
    const text = await res.text();

    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }

  function statusClass(status) {
    const normalized = String(status || '').toLowerCase();

    if (normalized.includes('healthy')) return 'healthy';
    if (normalized.includes('warning')) return 'warning';
    return 'critical';
  }

  function renderKpis(kpis) {
    const target = document.getElementById('regionalGatewayKpis');
    if (!target || !kpis) return;

    target.innerHTML = `
      <article><span>Countries</span><strong>${kpis.countries}</strong></article>
      <article><span>Gateway runtimes</span><strong>${kpis.gatewayRuntimes}</strong></article>
      <article><span>API products</span><strong>${kpis.apiProducts}</strong></article>
      <article><span>Monthly calls</span><strong>${compact(kpis.monthlyCalls)}</strong></article>
      <article><span>Avg latency</span><strong>${kpis.averageLatencyMs} ms</strong></article>
      <article><span>Availability</span><strong>${kpis.availabilityPct}%</strong></article>
      <article><span>Est. monthly revenue</span><strong>${money(kpis.estimatedMonthlyRevenueUsd)}</strong></article>
    `;
  }

  function renderRuntimes(runtimes) {
    const target = document.getElementById('regionalGatewayRuntimeGrid');
    if (!target || !Array.isArray(runtimes)) return;

    target.innerHTML = runtimes.map(runtime => `
      <article class="gateway-runtime-card ${statusClass(runtime.status)}">
        <div class="runtime-top">
          <div>
            <div class="card-kicker">${runtime.region}</div>
            <h3>${runtime.country}</h3>
          </div>
          <span>${runtime.status}</span>
        </div>

        <p>${runtime.businessFocus}</p>

        <dl>
          <div><dt>Runtime</dt><dd>${runtime.runtimeType}</dd></div>
          <div><dt>Deployment</dt><dd>${runtime.deployment}</dd></div>
          <div><dt>Latency</dt><dd>${runtime.latencyMs} ms</dd></div>
          <div><dt>Availability</dt><dd>${runtime.availabilityPct}%</dd></div>
          <div><dt>API products</dt><dd>${runtime.apiProducts}</dd></div>
          <div><dt>Monthly calls</dt><dd>${compact(runtime.monthlyCalls)}</dd></div>
        </dl>
      </article>
    `).join('');
  }

  function renderModel(items) {
    const target = document.getElementById('regionalGatewayModel');
    if (!target || !Array.isArray(items)) return;

    target.innerHTML = items.map(item => `
      <div class="gateway-model-row">
        <strong>${item.capability}</strong>
        <p>${item.description}</p>
      </div>
    `).join('');
  }

  async function refreshDashboard() {
    writeJson('regionalGatewayOutput', 'Loading regional gateway dashboard...');

    const data = await fetchJson('/api/v1/regional-gateways/dashboard');

    renderKpis(data.executiveKpis);
    renderRuntimes(data.federatedRuntimes);
    renderModel(data.federationModel);

    writeJson('regionalGatewayOutput', {
      story: data.businessStory,
      businessOutcome: data.businessOutcome,
      controlPlane: data.controlPlane,
      sampleRuntimeSignals: data.runtimeSignals?.slice(0, 2)
    });
  }

  async function simulateFailover() {
    writeJson('regionalGatewayOutput', 'Simulating regional failover...');

    const result = await fetchJson('/api/v1/regional-gateways/simulate-failover', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sourceRuntime: 'co-andes',
        targetRuntime: 'br-southeast'
      })
    });

    writeJson('regionalGatewayOutput', result);
  }

  function bind() {
    document.getElementById('refreshRegionalGateways')?.addEventListener('click', refreshDashboard);
    document.getElementById('simulateRegionalFailover')?.addEventListener('click', simulateFailover);

    if (document.getElementById('regionalGatewayKpis')) {
      refreshDashboard().catch(error => writeJson('regionalGatewayOutput', { error: error.message }));
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bind);
  } else {
    bind();
  }
})();

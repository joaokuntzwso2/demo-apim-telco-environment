(function () {
  const BACKEND = 'http://localhost:8081';

  const sections = {
    openGateway: {
      title: 'Open Gateway',
      subtitle: 'CAMARA-style Number Verification, SIM Swap Risk and Device Location Verification APIs packaged as a monetizable telco fraud-prevention product.',
      html: `
        <div class="rtx-native-content">
          <div class="rtx-tabs">
            <button class="rtx-tab active" data-rtx-tab="story">Story</button>
            <button class="rtx-tab" data-rtx-tab="live">Live API Results</button>
            <button class="rtx-tab" data-rtx-tab="commercial">Commercialization</button>
          </div>

          <section class="rtx-tab-panel active" data-rtx-panel="story">
            <div class="rtx-flow">
              <article><strong>1. Checkout starts</strong><span>Partner submits phone number and transaction context.</span></article>
              <article><strong>2. Network trust signals</strong><span>Number, SIM swap and location APIs evaluate fraud risk.</span></article>
              <article><strong>3. Risk decision</strong><span>Approve, step-up, hold or block the transaction.</span></article>
            </div>

            <div class="rtx-grid rtx-grid-3">
              <article class="rtx-card"><h3>Number Verification</h3><p>Confirms whether the phone number matches the mobile network subscriber context.</p><code>OpenGatewayNumberVerificationAPI</code></article>
              <article class="rtx-card"><h3>SIM Swap Risk</h3><p>Checks recent SIM swap activity before onboarding, payments or wallet recovery.</p><code>OpenGatewaySimSwapRiskAPI</code></article>
              <article class="rtx-card"><h3>Device Location Verification</h3><p>Validates whether the SIM-based device is inside the expected country or area.</p><code>OpenGatewayDeviceLocationVerificationAPI</code></article>
            </div>
          </section>

          <section class="rtx-tab-panel" data-rtx-panel="live">
            <div class="rtx-panel-header">
              <div>
                <h2>Live API Results</h2>
                <p>Run the local telco backend calls and show the fraud-prevention decision payload.</p>
              </div>
              <button class="rtx-primary" id="rtx-run-open-gateway">Run full fraud check</button>
            </div>

            <div class="rtx-results">
              <article class="rtx-result"><div><h3>Number Verification</h3><button data-rtx-run="number">Run</button></div><pre id="rtx-number-result">Waiting...</pre></article>
              <article class="rtx-result"><div><h3>SIM Swap Risk</h3><button data-rtx-run="sim">Run</button></div><pre id="rtx-sim-result">Waiting...</pre></article>
              <article class="rtx-result"><div><h3>Device Location</h3><button data-rtx-run="location">Run</button></div><pre id="rtx-location-result">Waiting...</pre></article>
              <article class="rtx-result"><div><h3>Final Decision</h3></div><pre id="rtx-decision-result">Run the full fraud check.</pre></article>
            </div>
          </section>

          <section class="rtx-tab-panel" data-rtx-panel="commercial">
            <div class="rtx-grid rtx-grid-2">
              <article class="rtx-card">
                <h3>Commercial product pack</h3>
                <p>The three APIs are exposed as a fraud-prevention API product, published and governed through WSO2 API Manager.</p>
                <div class="rtx-pills"><span>TelcoOpenGatewayTrustStarter</span><span>TelcoOpenGatewayTrustPremium</span><span>Telco Commercial APIs</span></div>
              </article>
              <article class="rtx-card">
                <h3>Moesif billing metadata</h3>
                <p>ConnectedAccountKey, RevenueShareModel, SettlementOwner, ProductLine and BillingCatalogReference are attached for downstream metering and settlement.</p>
              </article>
            </div>
          </section>
        </div>
      `
    },

    governanceScorecard: {
      title: 'Governance Scorecard',
      subtitle: 'A portfolio readiness view that turns governance, metadata, lifecycle and commercial controls into a business-readable scorecard.',
      html: `
        <div class="rtx-native-content">
          <div class="rtx-kpi-grid">
            <article><span>Overall readiness</span><strong>90%</strong></article>
            <article><span>Blocking issues</span><strong>0</strong></article>
            <article><span>Governed products</span><strong>6</strong></article>
            <article><span>Policy coverage</span><strong>4</strong></article>
          </div>

          <article class="rtx-card rtx-table-card">
            <h2>Portfolio scorecard</h2>
            <table class="rtx-table">
              <thead>
                <tr><th>API / product pack</th><th>Type</th><th>Lifecycle</th><th>Security</th><th>Metadata</th><th>Plans</th><th>Score</th></tr>
              </thead>
              <tbody>
                <tr><td>Open Gateway Fraud Prevention Pack</td><td>REST / CAMARA-style</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">98</span></td></tr>
                <tr><td>Customer360API</td><td>REST</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">94</span></td></tr>
                <tr><td>PartnerChargingAPI</td><td>REST</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">95</span></td></tr>
                <tr><td>NetworkEventsStreamAPI</td><td>SSE / Event API</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">90</span></td></tr>
                <tr><td>BillingAdjustmentSOAP</td><td>SOAP / Legacy</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-warn">Partial</span></td><td><span class="rtx-score-badge rtx-score-medium">84</span></td></tr>
                <tr><td>Candidate APIOps APIs</td><td>Pipeline candidates</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-warn">Partial</span></td><td><span class="rtx-status-warn">Partial</span></td><td><span class="rtx-score-badge rtx-score-medium">78</span></td></tr>
              </tbody>
            </table>
          </article>

          <div class="rtx-grid rtx-grid-4">
            <article class="rtx-card"><h3>Rule-to-pipeline</h3><p>Governance rules surface issues before publish and promotion.</p></article>
            <article class="rtx-card"><h3>Product readiness</h3><p>APIs carry owners, metadata, labels and commercial context.</p></article>
            <article class="rtx-card"><h3>Runtime enforcement</h3><p>Security, subscriptions and throttling are enforced through the gateway.</p></article>
            <article class="rtx-card"><h3>Multi-style governance</h3><p>REST, SOAP, streaming, GraphQL and Open Gateway follow one operating model.</p></article>
          </div>
        </div>
      `
    },

    demoCommander: {
      title: 'Demo Commander',
      subtitle: 'A guided control room for running the telco API platform demo with talk tracks, proof points and live checks.',
      html: `
        <div class="rtx-native-content">
          <div class="rtx-commander">
            <aside class="rtx-agenda">
              <button class="active" data-rtx-step="0">1. Platform opening</button>
              <button data-rtx-step="1">2. Open Gateway fraud journey</button>
              <button data-rtx-step="2">3. Governance proof</button>
              <button data-rtx-step="3">4. Commercialization</button>
              <button data-rtx-step="4">5. APIOps and multi-style APIs</button>
            </aside>

            <section class="rtx-stage">
              <div class="rtx-stage-top">
                <div><div class="rtx-card-kicker" id="rtx-step-kicker">Step 1</div><h2 id="rtx-step-title">Platform opening</h2></div>
                <span id="rtx-step-time">2 min</span>
              </div>

              <p id="rtx-step-summary"></p>
              <div class="rtx-card rtx-script-box"><h3>Talk track</h3><p id="rtx-step-talk"></p></div>
              <div class="rtx-card"><h3>Proof points</h3><ul id="rtx-step-proof"></ul></div>
            </section>
          </div>

          <article class="rtx-card">
            <div class="rtx-panel-header">
              <div><h2>Live platform check</h2><p>Validate backend and Open Gateway mock APIs before the demo.</p></div>
              <button class="rtx-primary" id="rtx-run-platform-check">Run platform check</button>
            </div>
            <pre class="rtx-json" id="rtx-platform-check-result">Waiting...</pre>
          </article>
        </div>
      `
    }
  };

  const commanderSteps = [
    ['Platform opening', '2 min', 'Frame the demo around API productization, governance and monetization.', 'We are showing how a regional telco exposes capabilities as secure, governed and monetizable API products.', ['Regional API business portal', 'Commercial plans', 'Multi-style API management']],
    ['Open Gateway fraud journey', '5 min', 'Show CAMARA-style network APIs as a fraud-prevention product pack.', 'A bank or marketplace combines number, SIM swap and location trust signals to make a transaction decision.', ['Number Verification', 'SIM Swap Risk', 'Device Location Verification', 'Final risk decision']],
    ['Governance proof', '4 min', 'Show governance as measurable controls, not just documentation.', 'The scorecard translates governance rules into business-readable readiness and policy coverage.', ['Governance labels', 'Metadata checks', 'Lifecycle control', 'Policy coverage']],
    ['Commercialization', '4 min', 'Show plans, subscriptions and billing metadata.', 'APIs are packaged with commercial plans and Moesif metadata for billing export and settlement.', ['Starter and Premium plans', 'ConnectedAccountKey', 'RevenueShareModel', 'BillingCatalogReference']],
    ['APIOps and multi-style APIs', '5 min', 'Close by showing REST, SOAP, streaming, GraphQL and pipeline candidates.', 'The same API operating model governs modern APIs, event APIs, legacy SOAP services and APIOps promotion.', ['NetworkEventsStreamAPI', 'BillingAdjustmentSOAP', 'Candidate APIs', 'APIOps pipeline']]
  ];

  function findContentContainer() {
    return (
      document.getElementById('contentGrid') ||
      document.getElementById('tabContent') ||
      document.querySelector('.content-grid') ||
      document.querySelector('main')
    );
  }

  function setHeader(section) {
    const title = document.getElementById('pageTitle') || document.querySelector('h1');
    const subtitle = document.getElementById('pageSubtitle') || document.querySelector('.page-subtitle');

    if (title) title.textContent = section.title;
    if (subtitle) subtitle.textContent = section.subtitle;
  }

  function setActiveNav(tab) {
    document.querySelectorAll('.nav-item').forEach(item => {
      item.classList.toggle('active', item.dataset.tab === tab);
    });
  }

  function renderSection(tab) {
    const section = sections[tab];
    const container = findContentContainer();

    if (!section || !container) return;

    setHeader(section);
    setActiveNav(tab);

    container.innerHTML = section.html;

    setupTabs(container);
    setupOpenGatewayLive(container);
    setupCommander(container);

    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function renderExtensionTabFromEvent(event) {
    const target = event.target && event.target.closest
      ? event.target.closest('.nav-item[data-tab]')
      : null;

    if (!target) {
      return;
    }

    const tab = target.dataset.tab;

    if (!sections[tab]) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    if (event.stopImmediatePropagation) {
      event.stopImmediatePropagation();
    }

    renderSection(tab);

    // Re-apply after the native app event cycle, in case app.js also tried to render.
    window.requestAnimationFrame(() => renderSection(tab));
    window.setTimeout(() => renderSection(tab), 75);
  }

  function bindNativeButtons() {
    if (window.__rtxNativeTabInterceptorInstalled) {
      return;
    }

    window.__rtxNativeTabInterceptorInstalled = true;

    window.addEventListener('click', renderExtensionTabFromEvent, true);
  }

  function setupTabs(root) {
    const tabs = Array.from(root.querySelectorAll('.rtx-tab'));
    const panels = Array.from(root.querySelectorAll('.rtx-tab-panel'));

    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        const name = tab.dataset.rtxTab;
        tabs.forEach(item => item.classList.toggle('active', item === tab));
        panels.forEach(panel => panel.classList.toggle('active', panel.dataset.rtxPanel === name));
      });
    });
  }

  function setJson(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  }

  async function fetchJson(url, options) {
    const res = await fetch(url, options);
    const text = await res.text();
    try { return JSON.parse(text); } catch { return text; }
  }

  function setupOpenGatewayLive(root) {
    const state = {};

    async function number() {
      setJson('rtx-number-result', 'Calling...');
      state.number = await fetchJson(`${BACKEND}/api/v1/open-gateway/number-verification/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phoneNumber: '+5511999990001', expectedSubscriberId: 'customer-001' })
      });
      setJson('rtx-number-result', state.number);
    }

    async function sim() {
      setJson('rtx-sim-result', 'Calling...');
      state.sim = await fetchJson(`${BACKEND}/api/v1/open-gateway/sim-swap/${encodeURIComponent('+5511999990001')}/risk`);
      setJson('rtx-sim-result', state.sim);
    }

    async function location() {
      setJson('rtx-location-result', 'Calling...');
      state.location = await fetchJson(`${BACKEND}/api/v1/open-gateway/device-location/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phoneNumber: '+5511999990001', countryCode: 'BR', latitude: -23.5505, longitude: -46.6333, radiusMeters: 5000 })
      });
      setJson('rtx-location-result', state.location);
    }

    root.querySelector('[data-rtx-run="number"]')?.addEventListener('click', number);
    root.querySelector('[data-rtx-run="sim"]')?.addEventListener('click', sim);
    root.querySelector('[data-rtx-run="location"]')?.addEventListener('click', location);
    root.querySelector('#rtx-run-open-gateway')?.addEventListener('click', async () => {
      await number();
      await sim();
      await location();
      setJson('rtx-decision-result', { decision: 'APPROVE_OR_STEP_UP', reason: 'Decision composed from number, SIM swap and location trust signals.', signals: state });
    });
  }

  function setupCommander(root) {
    const buttons = Array.from(root.querySelectorAll('[data-rtx-step]'));

    function renderStep(index) {
      const [title, time, summary, talk, proof] = commanderSteps[index];

      root.querySelector('#rtx-step-kicker').textContent = `Step ${index + 1}`;
      root.querySelector('#rtx-step-title').textContent = title;
      root.querySelector('#rtx-step-time').textContent = time;
      root.querySelector('#rtx-step-summary').textContent = summary;
      root.querySelector('#rtx-step-talk').textContent = talk;
      root.querySelector('#rtx-step-proof').innerHTML = proof.map(item => `<li>${item}</li>`).join('');

      buttons.forEach(button => button.classList.toggle('active', Number(button.dataset.rtxStep) === index));
    }

    buttons.forEach(button => button.addEventListener('click', () => renderStep(Number(button.dataset.rtxStep))));

    root.querySelector('#rtx-run-platform-check')?.addEventListener('click', async () => {
      setJson('rtx-platform-check-result', 'Running checks...');

      const result = {
        backendHealth: await fetchJson(`${BACKEND}/health`),
        numberVerification: await fetchJson(`${BACKEND}/api/v1/open-gateway/number-verification/verify`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ phoneNumber: '+5511999990001', expectedSubscriberId: 'customer-001' })
        }),
        simSwapRisk: await fetchJson(`${BACKEND}/api/v1/open-gateway/sim-swap/${encodeURIComponent('+5511999990001')}/risk`)
      };

      setJson('rtx-platform-check-result', result);
    });

    if (buttons.length) renderStep(0);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bindNativeButtons);
  } else {
    bindNativeButtons();
  }

  window.setTimeout(bindNativeButtons, 100);
  window.setTimeout(bindNativeButtons, 500);
})();

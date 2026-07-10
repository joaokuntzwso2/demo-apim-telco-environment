(function () {
  const BACKEND = window.PORTAL_CONFIG?.backendUrl || 'http://localhost:8081';

  const commanderSteps = [
    {
      title: 'Platform opening',
      time: '2 min',
      talk: 'Position the demo as an API business platform for a regional telco group, not only as a gateway demo.',
      proof: ['Single API control plane', 'Multi-country operating model', 'API productization']
    },
    {
      title: 'Open Gateway fraud journey',
      time: '5 min',
      talk: 'Show how number verification, SIM swap risk and device location become a premium fraud-prevention product.',
      proof: ['CAMARA-style APIs', 'Fraud decision payload', 'Commercial package']
    },
    {
      title: 'Governance proof',
      time: '4 min',
      talk: 'Translate governance into a scorecard that business and technical stakeholders can both understand.',
      proof: ['Lifecycle coverage', 'Metadata coverage', 'Commercial plans', 'Policy enforcement']
    },
    {
      title: 'Moesif monetization export',
      time: '4 min',
      talk: 'Show how WSO2 owns API product exposure while Moesif receives product, meter and settlement metadata.',
      proof: ['Billing catalog reference', 'Product keys', 'Revenue share models', 'Settlement owner']
    },
    {
      title: 'Event-native broker monetization',
      time: '4 min',
      talk: 'Show that the telco can productize event streams as Kafka-style topics, not only synchronous REST APIs. Partners subscribe to governed network, fraud and settlement events, and each delivered event becomes a billable Moesif meter.',
      proof: ['Kafka-style topic catalog', 'Broker event delivery', 'SLA alert metering', 'Event-stream settlement']
    },
    {
      title: 'Regional federated gateways',
      time: '4 min',
      talk: 'Show how a regional telco group can keep central API governance while executing traffic through country, cloud, edge and event-native gateway runtimes.',
      proof: ['Central control plane', 'Country gateway estate', 'Edge runtime visibility', 'Regional failover simulation']
    }
  ];

  const panels = {
    openGateway: `
      <div class="rtx-native-content">
        <div class="rtx-grid rtx-grid-3">
          <article class="rtx-card">
            <h3>Number Verification</h3>
            <p>Confirms whether the phone number matches the expected subscriber context.</p>
            <code>OpenGatewayNumberVerificationAPI</code>
          </article>
          <article class="rtx-card">
            <h3>SIM Swap Risk</h3>
            <p>Checks recent SIM swap activity before onboarding, checkout or account recovery.</p>
            <code>OpenGatewaySimSwapRiskAPI</code>
          </article>
          <article class="rtx-card">
            <h3>Device Location Verification</h3>
            <p>Validates whether the SIM-based device is inside the expected area.</p>
            <code>OpenGatewayDeviceLocationVerificationAPI</code>
          </article>
        </div>

        <article class="rtx-card">
          <div class="rtx-panel-header">
            <div>
              <h2>Live fraud-prevention decision</h2>
              <p>Runs the three Open Gateway-style trust signals and produces a decision payload.</p>
            </div>
            <button class="rtx-primary" id="rtx-run-open-gateway">Run fraud check</button>
          </div>
          <pre class="rtx-json" id="rtx-open-gateway-result">Waiting...</pre>
        </article>

        <div class="rtx-grid rtx-grid-2">
          <article class="rtx-card">
            <h3>Business story</h3>
            <p>A bank, wallet or marketplace uses network trust signals to reduce fraud while keeping the checkout experience smooth.</p>
          </article>
          <article class="rtx-card">
            <h3>Commercial outcome</h3>
            <p>The telco monetizes network intelligence as a premium API Product bundle instead of exposing isolated technical APIs.</p>
          </article>
        </div>
      </div>
    `,

    governanceScorecard: `
      <div class="rtx-native-content">
        <div class="rtx-kpi-grid">
          <article><span>Overall readiness</span><strong>90%</strong></article>
          <article><span>Blocking issues</span><strong>0</strong></article>
          <article><span>Native API Products</span><strong>3</strong></article>
          <article><span>Moesif meters</span><strong>12+</strong></article>
        </div>

        <article class="rtx-card rtx-table-card">
          <h2>Portfolio scorecard</h2>
          <table class="rtx-table">
            <thead>
              <tr><th>Bundle</th><th>Type</th><th>Lifecycle</th><th>Security</th><th>Metadata</th><th>Plans</th><th>Score</th></tr>
            </thead>
            <tbody>
              <tr><td>Open Gateway Fraud Defense</td><td>API Product</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">98</span></td></tr>
              <tr><td>Digital Customer & BSS Experience</td><td>API Product</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">94</span></td></tr>
              <tr><td>5G Network Monetization</td><td>API Product</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-score-badge rtx-score-high">91</span></td></tr>
              <tr><td>Legacy BSS Modernization</td><td>Metadata bundle</td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-ok">Yes</span></td><td><span class="rtx-status-warn">Partial</span></td><td><span class="rtx-score-badge rtx-score-medium">84</span></td></tr>
            </tbody>
          </table>
        </article>
      </div>
    `,

    demoCommander: `
      <div class="rtx-native-content">
        <div class="rtx-commander">
          <aside class="rtx-agenda">
            ${commanderSteps.map((step, index) => `<button class="${index === 0 ? 'active' : ''}" data-rtx-step="${index}">${index + 1}. ${step.title}</button>`).join('')}
          </aside>
          <section class="rtx-stage">
            <div class="rtx-stage-top">
              <div>
                <div class="rtx-card-kicker" id="rtx-step-kicker">Step 1</div>
                <h2 id="rtx-step-title"></h2>
              </div>
              <span id="rtx-step-time"></span>
            </div>
            <article class="rtx-card">
              <h3>Operational guidance</h3>
              <p id="rtx-step-talk"></p>
            </article>
            <article class="rtx-card">
              <h3>Proof points</h3>
              <ul id="rtx-step-proof"></ul>
            </article>
          </section>
        </div>

        <article class="rtx-card">
          <div class="rtx-panel-header">
            <div>
              <h2>Live platform check</h2>
              <p>Validates the backend and Moesif export artifact before the demo.</p>
            </div>
            <button class="rtx-primary" id="rtx-run-platform-check">Run platform check</button>
          </div>
          <pre class="rtx-json" id="rtx-platform-check-result">Waiting...</pre>
        </article>
      </div>
    `
  };

  function ensurePanel(tab) {
    let panel = document.getElementById(`tab-${tab}`);

    if (!panel) {
      panel = document.createElement('section');
      panel.id = `tab-${tab}`;
      panel.className = 'tab-panel';

      const runtimePanel = document.getElementById('tab-runtime');
      if (runtimePanel?.parentElement) {
        runtimePanel.parentElement.insertBefore(panel, runtimePanel.nextSibling);
      } else {
        document.querySelector('main')?.appendChild(panel);
      }
    }

    return panel;
  }

  function renderPanels() {
    for (const [tab, html] of Object.entries(panels)) {
      ensurePanel(tab).innerHTML = html;
    }

    setupOpenGateway();
    setupCommander();
  }

  async function fetchJson(url, options) {
    const res = await fetch(url, options);
    const text = await res.text();
    try { return JSON.parse(text); } catch { return text; }
  }

  function writeJson(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  }

  function setupOpenGateway() {
    document.getElementById('rtx-run-open-gateway')?.addEventListener('click', async () => {
      writeJson('rtx-open-gateway-result', 'Calling Open Gateway trust signals...');

      const numberVerification = await fetchJson(`${BACKEND}/api/v1/open-gateway/number-verification/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phoneNumber: '+5511999990001', expectedSubscriberId: 'customer-001' })
      });

      const simSwapRisk = await fetchJson(`${BACKEND}/api/v1/open-gateway/sim-swap/${encodeURIComponent('+5511999990001')}/risk`);

      const deviceLocation = await fetchJson(`${BACKEND}/api/v1/open-gateway/device-location/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phoneNumber: '+5511999990001', countryCode: 'BR', latitude: -23.5505, longitude: -46.6333, radiusMeters: 5000 })
      });

      writeJson('rtx-open-gateway-result', {
        decision: 'APPROVE_OR_STEP_UP',
        businessMeaning: 'A partner can combine telco trust signals into a fraud decision without integrating separately with each network system.',
        signals: { numberVerification, simSwapRisk, deviceLocation }
      });
    });
  }

  function setupCommander() {
    const root = document.getElementById('tab-demoCommander');
    if (!root) return;

    const buttons = Array.from(root.querySelectorAll('[data-rtx-step]'));

    function renderStep(index) {
      const step = commanderSteps[index];

      root.querySelector('#rtx-step-kicker').textContent = `Step ${index + 1}`;
      root.querySelector('#rtx-step-title').textContent = step.title;
      root.querySelector('#rtx-step-time').textContent = step.time;
      root.querySelector('#rtx-step-talk').textContent = step.talk;
      root.querySelector('#rtx-step-proof').innerHTML = step.proof.map(item => `<li>${item}</li>`).join('');

      buttons.forEach(button => {
        button.classList.toggle('active', Number(button.dataset.rtxStep) === index);
      });
    }

    buttons.forEach(button => {
      button.addEventListener('click', () => renderStep(Number(button.dataset.rtxStep)));
    });

    document.getElementById('rtx-run-platform-check')?.addEventListener('click', async () => {
      writeJson('rtx-platform-check-result', 'Running checks...');

      const result = {
        backendHealth: await fetchJson(`${BACKEND}/health`),
        apiProductBundles: await fetchJson(`${BACKEND}/api/v1/api-product-bundles`),
        moesifExport: await fetchJson(`${BACKEND}/api/v1/moesif/export`),
        eventBrokerSimulation: await fetchJson(`${BACKEND}/api/v1/event-broker/simulation`),
        eventBrokerIncident: await fetchJson(`${BACKEND}/api/v1/event-broker/simulate/network-incident`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ partnerId: 'enterprise-private-5g', country: 'BR', region: 'Sao Paulo' })
        })
      };

      writeJson('rtx-platform-check-result', result);
    });

    renderStep(0);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderPanels);
  } else {
    renderPanels();
  }
})();

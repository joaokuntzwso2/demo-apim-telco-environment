(function () {
  const BACKEND = 'http://localhost:8081';

  const steps = [
    {
      title: 'Opening: API platform as a business product factory',
      time: '2 min',
      summary: 'Frame the demo around API productization, not just API publishing.',
      talk: 'We are showing how a regional telco can expose capabilities as governed, secure and monetizable API products across countries, partners and API styles.',
      proofs: [
        'Regional API business portal',
        'Commercial API products and plans',
        'Single operating model for REST, streaming, SOAP, GraphQL and Open Gateway'
      ],
      actions: [
        ['Open portal overview', '/'],
        ['Open governance scorecard', '/governance-scorecard.html']
      ]
    },
    {
      title: 'Open Gateway fraud-prevention journey',
      time: '5 min',
      summary: 'Show how CAMARA-style network APIs become a commercial fraud-prevention pack.',
      talk: 'A bank or marketplace can call Number Verification, SIM Swap Risk and Device Location Verification to make a better transaction decision.',
      proofs: [
        'Number Verification API',
        'SIM Swap Risk API',
        'Device Location Verification API',
        'Live JSON results and final decision'
      ],
      actions: [
        ['Open Open Gateway story', '/open-gateway.html'],
        ['Run live API results', '/open-gateway.html#live']
      ]
    },
    {
      title: 'Governance proof: from rule to enforcement',
      time: '4 min',
      summary: 'Show that governance is visible, measurable and connected to lifecycle decisions.',
      talk: 'The scorecard translates governance into a business-readable view while the platform still enforces policies, labels, lifecycle controls and runtime security.',
      proofs: [
        'Governance labels',
        'Metadata readiness',
        'Lifecycle readiness',
        'Policy coverage across API types'
      ],
      actions: [
        ['Open Governance Scorecard', '/governance-scorecard.html'],
        ['Open Publisher', 'https://localhost:9443/publisher']
      ]
    },
    {
      title: 'Commercialization and monetization',
      time: '4 min',
      summary: 'Show subscriptions, plans, Moesif metadata and revenue-share readiness.',
      talk: 'APIs are packaged with subscription plans and exported billing metadata, so the platform supports both technical onboarding and commercial operations.',
      proofs: [
        'TelcoOpenGatewayTrustStarter',
        'TelcoOpenGatewayTrustPremium',
        'ConnectedAccountKey and BillingCatalogReference',
        'Moesif export metadata'
      ],
      actions: [
        ['Open DevPortal', 'https://localhost:9443/devportal'],
        ['Open Open Gateway commercialization tab', '/open-gateway.html#commercial']
      ]
    },
    {
      title: 'APIOps, legacy and event-native coverage',
      time: '5 min',
      summary: 'Close by showing the breadth of the platform: API creation, APIOps, streaming and SOAP modernization.',
      talk: 'The same platform can govern modern REST APIs, legacy SOAP services, event APIs and pipeline-promoted candidate APIs.',
      proofs: [
        'APIOps pipeline portal',
        'NetworkEventsStreamAPI',
        'BillingAdjustmentSOAP',
        'Governed candidate APIs'
      ],
      actions: [
        ['Open API Delivery Pipeline', 'http://localhost:8090'],
        ['Open Publisher', 'https://localhost:9443/publisher']
      ]
    }
  ];

  let active = 0;

  function renderSteps() {
    const list = document.getElementById('commander-steps');
    list.innerHTML = steps.map((step, index) => `
      <li>
        <button class="${index === active ? 'active' : ''}" data-step="${index}">
          <span>${index + 1}</span>
          ${step.title}
        </button>
      </li>
    `).join('');

    list.querySelectorAll('button').forEach(button => {
      button.addEventListener('click', () => {
        active = Number(button.dataset.step);
        render();
      });
    });
  }

  function render() {
    const step = steps[active];

    document.getElementById('commander-kicker').textContent = `Step ${active + 1}`;
    document.getElementById('commander-title').textContent = step.title;
    document.getElementById('commander-time').textContent = step.time;
    document.getElementById('commander-summary').textContent = step.summary;
    document.getElementById('commander-talktrack').textContent = step.talk;

    document.getElementById('commander-proof').innerHTML =
      step.proofs.map(item => `<li>${item}</li>`).join('');

    document.getElementById('commander-actions').innerHTML =
      step.actions.map(([label, href]) => `
        <a href="${href}" ${href.startsWith('http') ? 'target="_blank"' : ''}>${label}</a>
      `).join('');

    renderSteps();
  }

  async function fetchJson(url, options) {
    const response = await fetch(url, options);
    const text = await response.text();

    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }

    return {
      ok: response.ok,
      status: response.status,
      body
    };
  }

  async function runHealth() {
    const output = document.getElementById('commander-output');
    output.textContent = 'Running platform checks...';

    const results = {};

    results.backendHealth = await fetchJson(`${BACKEND}/health`);

    results.numberVerification = await fetchJson(`${BACKEND}/api/v1/open-gateway/number-verification/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        phoneNumber: '+5511999990001',
        expectedSubscriberId: 'customer-001'
      })
    });

    results.simSwapRisk = await fetchJson(`${BACKEND}/api/v1/open-gateway/sim-swap/${encodeURIComponent('+5511999990001')}/risk`);

    results.deviceLocation = await fetchJson(`${BACKEND}/api/v1/open-gateway/device-location/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        phoneNumber: '+5511999990001',
        countryCode: 'BR',
        latitude: -23.5505,
        longitude: -46.6333,
        radiusMeters: 5000
      })
    });

    output.textContent = JSON.stringify(results, null, 2);
  }

  document.getElementById('commander-run-health')?.addEventListener('click', runHealth);

  render();
})();

(function () {
  const BACKEND = window.DEMO_CONFIG?.backendUrl || `${window.location.protocol}//${window.location.hostname}:8081`;

  function safeText(value) {
    return String(value ?? '-')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#039;');
  }

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  function output(value) {
    const el = document.getElementById('siddhiGovernanceOutput');
    if (el) {
      el.textContent = typeof value === 'string' ? value : pretty(value);
    }
  }

  async function fetchJson(path) {
    const res = await fetch(`${BACKEND}${path}`, {
      cache: 'no-store'
    });

    const text = await res.text();

    try {
      return JSON.parse(text);
    } catch {
      return {
        error: 'non_json_response',
        payload: text
      };
    }
  }

  function renderSummary(data) {
    const target = document.getElementById('siddhiValidationSummary');
    if (!target) return;

    const validations = Array.isArray(data?.validations) ? data.validations : [];

    target.innerHTML = validations.map(item => `
      <article class="siddhi-validation-card ${item.pass ? 'pass' : 'deny'}">
        <div>
          <span>${safeText(item.id)}</span>
          <h3>${safeText(item.name)}</h3>
        </div>
        <strong>${item.pass ? 'PASS' : 'DENY'}</strong>
        <p>${safeText(item.businessMeaning || item.story || '')}</p>
      </article>
    `).join('');
  }

  async function runSiddhiValidation() {
    const button = document.getElementById('runSiddhiGovernance');

    output('Running Siddhi query validation...');

    if (button) {
      button.disabled = true;
      button.textContent = 'Running...';
    }

    try {
      const data = await fetchJson('/api/v1/siddhi/governance/evaluate');
      renderSummary(data);
      output(data);
    } catch (error) {
      output({
        status: 'Siddhi governance UI error',
        message: error.message
      });
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = 'Run Siddhi validation';
      }
    }
  }

  function injectCard() {
    const panel =
      document.getElementById('tab-governanceScorecard') ||
      document.getElementById('tab-streaming') ||
      document.querySelector('main');

    if (!panel || document.getElementById('siddhiGovernanceCard')) return;

    const card = document.createElement('article');
    card.id = 'siddhiGovernanceCard';
    card.className = 'story-card siddhi-governance-card';

    card.innerHTML = `
      <div class="section-heading">
        <div>
          <div class="card-kicker">Siddhi streaming governance</div>
          <h2>Real-time telco event query validation</h2>
          <p>
            Siddhi validates the event-processing logic behind network assurance, SIM swap fraud prevention
            and partner settlement before APIM exposes those capabilities as API and event products.
          </p>
        </div>
        <button class="siddhi-action" id="runSiddhiGovernance" type="button">Run Siddhi validation</button>
      </div>

      <div class="siddhi-policy-grid">
        <div><strong>1</strong><span>QoD SLA degradation</span></div>
        <div><strong>2</strong><span>SIM swap fraud guard</span></div>
        <div><strong>3</strong><span>Partner settlement metering</span></div>
      </div>

      <div id="siddhiValidationSummary" class="siddhi-validation-summary"></div>
      <pre id="siddhiGovernanceOutput" class="siddhi-output">Ready. Click "Run Siddhi validation".</pre>
    `;

    panel.appendChild(card);

    document.getElementById('runSiddhiGovernance')?.addEventListener('click', runSiddhiValidation);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectCard);
  } else {
    injectCard();
  }

  window.runTelcoSiddhiValidation = runSiddhiValidation;
})();

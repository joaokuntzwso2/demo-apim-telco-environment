(function () {
  const BACKEND = window.PORTAL_CONFIG?.backendUrl || `${window.location.protocol}//${window.location.hostname}:8081`;

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  function output(value) {
    const el = document.getElementById('opaGovernanceOutput');
    if (el) el.textContent = typeof value === 'string' ? value : pretty(value);
  }

  async function fetchJson(path) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);

    try {
      const res = await fetch(`${BACKEND}${path}`, {
        signal: controller.signal
      });

      const text = await res.text();

      let payload;
      try {
        payload = JSON.parse(text);
      } catch {
        payload = text;
      }

      if (!res.ok) {
        return {
          error: 'request_failed',
          status: res.status,
          payload
        };
      }

      return payload;
    } catch (error) {
      return {
        error: error.name === 'AbortError' ? 'request_timeout' : 'request_error',
        message: error.message,
        backend: BACKEND,
        path
      };
    } finally {
      clearTimeout(timeout);
    }
  }

  function renderValidationSummary(data) {
    const target = document.getElementById('opaValidationSummary');
    if (!target || !data?.validations) return;

    target.innerHTML = data.validations.map(item => {
      const allow = item.decision?.allow === true;
      const deny = item.decision?.deny || [];
      const warn = item.decision?.warn || [];

      return `
        <article class="opa-validation-card ${allow ? 'pass' : 'deny'}">
          <div>
            <span>${item.kind.replaceAll('_', ' ')}</span>
            <h3>${item.name}</h3>
          </div>
          <strong>${allow ? 'PASS' : 'DENY'}</strong>
          ${warn.length ? `<p class="opa-warning">${warn.join('<br>')}</p>` : ''}
          ${deny.length ? `<p class="opa-deny">${deny.join('<br>')}</p>` : ''}
        </article>
      `;
    }).join('');
  }

  async function runOpaValidation() {
    output('Running OPA governance validation...');

    const button = document.getElementById('runOpaGovernance');
    if (button) {
      button.disabled = true;
      button.textContent = 'Running...';
    }

    try {
      const data = await fetchJson('/api/v1/opa/governance/evaluate');

      if (data?.error) {
        output({
          status: 'OPA governance validation failed',
          hint: 'Check backend, OPA container health, and whether telco-backend can reach http://opa:8181.',
          ...data
        });
        return;
      }

      renderValidationSummary(data);
      output(data);
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = 'Run OPA validations';
      }
    }
  }

  function injectCard() {
    const panel =
      document.getElementById('tab-governanceScorecard') ||
      document.getElementById('tab-regionalGateways') ||
      document.querySelector('main');

    if (!panel || document.getElementById('opaGovernanceCard')) return;

    const card = document.createElement('article');
    card.id = 'opaGovernanceCard';
    card.className = 'story-card opa-governance-card';
    card.innerHTML = `
      <div class="section-heading">
        <div>
          <div class="card-kicker">OPA policy-as-code</div>
          <h2>APIM governance decision point</h2>
          <p>
            OPA validates that telco API products are commercially ready, high-risk Open Gateway capabilities have guardrails,
            and regional gateway failover is available before the platform is demonstrated.
          </p>
        </div>
        <button class="opa-action" id="runOpaGovernance">Run OPA validations</button>
      </div>

      <div class="opa-policy-grid">
        <div><strong>1</strong><span>Commercial API Product metadata</span></div>
        <div><strong>2</strong><span>High-risk Open Gateway controls</span></div>
        <div><strong>3</strong><span>Regional gateway failover readiness</span></div>
      </div>

      <div id="opaValidationSummary" class="opa-validation-summary"></div>
      <pre id="opaGovernanceOutput" class="opa-output">Waiting...</pre>
    `;

    panel.appendChild(card);

    document.getElementById('runOpaGovernance')?.addEventListener('click', runOpaValidation);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectCard);
  } else {
    injectCard();
  }
})();

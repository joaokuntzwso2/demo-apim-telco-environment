(function () {
  const BACKEND_BASE = 'http://localhost:8081';

  const scenario = {
    phoneNumber: '+5511999990001',
    expectedSubscriberId: 'customer-001',
    countryCode: 'BR',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusMeters: 5000
  };

  const state = {
    number: null,
    sim: null,
    location: null
  };

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  function setResult(id, value) {
    document.getElementById(id).textContent =
      typeof value === 'string' ? value : pretty(value);
  }

  async function parseResponse(response) {
    const text = await response.text();

    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }

    if (!response.ok) {
      throw new Error(pretty({
        status: response.status,
        statusText: response.statusText,
        body
      }));
    }

    return body;
  }

  async function runNumberVerification() {
    setResult('og-result-number', 'Calling Number Verification API...');

    const response = await fetch(`${BACKEND_BASE}/api/v1/open-gateway/number-verification/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        phoneNumber: scenario.phoneNumber,
        expectedSubscriberId: scenario.expectedSubscriberId
      })
    });

    state.number = await parseResponse(response);
    setResult('og-result-number', state.number);
    return state.number;
  }

  async function runSimSwapRisk() {
    setResult('og-result-sim', 'Calling SIM Swap Risk API...');

    const response = await fetch(
      `${BACKEND_BASE}/api/v1/open-gateway/sim-swap/${encodeURIComponent(scenario.phoneNumber)}/risk`
    );

    state.sim = await parseResponse(response);
    setResult('og-result-sim', state.sim);
    return state.sim;
  }

  async function runDeviceLocation() {
    setResult('og-result-location', 'Calling Device Location Verification API...');

    const response = await fetch(`${BACKEND_BASE}/api/v1/open-gateway/device-location/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        phoneNumber: scenario.phoneNumber,
        countryCode: scenario.countryCode,
        latitude: scenario.latitude,
        longitude: scenario.longitude,
        radiusMeters: scenario.radiusMeters
      })
    });

    state.location = await parseResponse(response);
    setResult('og-result-location', state.location);
    return state.location;
  }

  function riskText(value) {
    return String(value || '').toLowerCase();
  }

  function computeDecision() {
    const numberOk =
      state.number?.verified === true ||
      state.number?.match === true ||
      state.number?.numberVerified === true ||
      state.number?.result === 'MATCH';

    const simRisk =
      riskText(state.sim?.riskLevel || state.sim?.risk || state.sim?.simSwapRisk);

    const locationOk =
      state.location?.verified === true ||
      state.location?.insideExpectedArea === true ||
      state.location?.locationVerified === true ||
      state.location?.result === 'MATCH';

    let decision = 'STEP_UP_AUTHENTICATION';
    let reason = 'One or more telco trust signals require additional verification.';

    if (numberOk && locationOk && !['high', 'critical'].includes(simRisk)) {
      decision = 'APPROVE';
      reason = 'Number, SIM and location signals are consistent with the transaction.';
    }

    if (!numberOk || simRisk === 'critical') {
      decision = 'BLOCK_OR_MANUAL_REVIEW';
      reason = 'Identity or SIM swap signal indicates elevated fraud risk.';
    }

    const result = {
      decision,
      reason,
      signals: {
        numberVerification: state.number,
        simSwapRisk: state.sim,
        deviceLocation: state.location
      }
    };

    setResult('og-result-decision', result);
    return result;
  }

  async function runFullCheck() {
    try {
      await runNumberVerification();
      await runSimSwapRisk();
      await runDeviceLocation();
      computeDecision();
    } catch (e) {
      setResult('og-result-decision', String(e.message || e));
    }
  }

  function activateTab(name) {
    const tabs = Array.from(document.querySelectorAll('.og-tab'));
    const panels = Array.from(document.querySelectorAll('.og-panel'));

    const selected = tabs.find(tab => tab.dataset.tab === name) || tabs[0];

    tabs.forEach(item => item.classList.toggle('active', item === selected));
    panels.forEach(panel => panel.classList.toggle('active', panel.dataset.panel === selected.dataset.tab));
  }

  function setupTabs() {
    const tabs = Array.from(document.querySelectorAll('.og-tab'));

    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        const name = tab.dataset.tab;
        activateTab(name);
        history.replaceState(null, '', `#${name}`);
      });
    });

    const initial = window.location.hash.replace('#', '') || 'story';
    activateTab(initial);

    if (initial === 'live') {
      setTimeout(() => {
        document.getElementById('og-run-all')?.focus();
      }, 100);
    }
  }

  function setupActions() {
    document.querySelector('[data-run="number"]')?.addEventListener('click', async () => {
      try {
        await runNumberVerification();
      } catch (e) {
        setResult('og-result-number', String(e.message || e));
      }
    });

    document.querySelector('[data-run="sim"]')?.addEventListener('click', async () => {
      try {
        await runSimSwapRisk();
      } catch (e) {
        setResult('og-result-sim', String(e.message || e));
      }
    });

    document.querySelector('[data-run="location"]')?.addEventListener('click', async () => {
      try {
        await runDeviceLocation();
      } catch (e) {
        setResult('og-result-location', String(e.message || e));
      }
    });

    document.getElementById('og-run-all')?.addEventListener('click', runFullCheck);
  }

  setupTabs();
  setupActions();
})();

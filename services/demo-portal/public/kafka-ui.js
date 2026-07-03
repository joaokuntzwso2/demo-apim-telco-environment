(function () {
  const BACKEND = window.DEMO_CONFIG?.backendUrl || 'http://localhost:8081';
  const TOPIC = 'telco.network.qod.events';

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  function output(value) {
    const target = document.getElementById('kafkaUiOutput');
    if (target) target.textContent = typeof value === 'string' ? value : pretty(value);
  }

  async function fetchJson(url, options) {
    const response = await fetch(url, options);
    const text = await response.text();

    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }

  async function refreshStatus() {
    output('Loading Kafka status...');
    const status = await fetchJson(`${BACKEND}/api/v1/kafka/status`);
    output(status);
  }

  async function publishIncident() {
    output('Publishing real Kafka network SLA event...');

    const payload = {
      partnerId: document.getElementById('kafkaPartnerId')?.value || 'enterprise-private-5g',
      country: document.getElementById('kafkaCountry')?.value || 'BR',
      region: document.getElementById('kafkaRegion')?.value || 'Sao Paulo',
      severity: document.getElementById('kafkaSeverity')?.value || 'CRITICAL'
    };

    const result = await fetchJson(`${BACKEND}/api/v1/kafka/produce-network-incident`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    output(result);
  }

  async function consumeEvents() {
    output('Reading recent Kafka events...');
    const events = await fetchJson(`${BACKEND}/api/v1/kafka/topics/${encodeURIComponent(TOPIC)}/events`);
    output(events);
  }

  function bind() {
    document.getElementById('kafkaRefreshStatus')?.addEventListener('click', refreshStatus);
    document.getElementById('kafkaPublishIncident')?.addEventListener('click', publishIncident);
    document.getElementById('kafkaConsumeEvents')?.addEventListener('click', consumeEvents);

    if (document.getElementById('kafkaUiOutput')) {
      refreshStatus().catch(error => output({ error: error.message }));
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bind);
  } else {
    bind();
  }
})();

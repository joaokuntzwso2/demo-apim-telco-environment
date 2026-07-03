(function () {
  const rows = [
    {
      name: 'Open Gateway Fraud Prevention Pack',
      type: 'REST / CAMARA-style',
      lifecycle: true,
      security: true,
      metadata: true,
      plans: true,
      score: 98,
      status: 'Ready'
    },
    {
      name: 'Customer360API',
      type: 'REST',
      lifecycle: true,
      security: true,
      metadata: true,
      plans: true,
      score: 94,
      status: 'Ready'
    },
    {
      name: 'PartnerChargingAPI',
      type: 'REST',
      lifecycle: true,
      security: true,
      metadata: true,
      plans: true,
      score: 95,
      status: 'Ready'
    },
    {
      name: 'NetworkEventsStreamAPI',
      type: 'SSE / Event API',
      lifecycle: true,
      security: true,
      metadata: true,
      plans: true,
      score: 90,
      status: 'Ready'
    },
    {
      name: 'BillingAdjustmentSOAP',
      type: 'SOAP / Legacy',
      lifecycle: true,
      security: true,
      metadata: true,
      plans: false,
      score: 84,
      status: 'Governed'
    },
    {
      name: 'Candidate APIOps APIs',
      type: 'Pipeline candidates',
      lifecycle: true,
      security: true,
      metadata: false,
      plans: false,
      score: 78,
      status: 'Pre-publish'
    }
  ];

  function yes(value) {
    return value ? '<span class="score-ok">Yes</span>' : '<span class="score-warn">Partial</span>';
  }

  function scoreClass(score) {
    if (score >= 90) return 'score-high';
    if (score >= 80) return 'score-medium';
    return 'score-low';
  }

  function render() {
    const body = document.getElementById('score-table-body');

    body.innerHTML = rows.map(row => `
      <tr>
        <td><strong>${row.name}</strong></td>
        <td>${row.type}</td>
        <td>${yes(row.lifecycle)}</td>
        <td>${yes(row.security)}</td>
        <td>${yes(row.metadata)}</td>
        <td>${yes(row.plans)}</td>
        <td><span class="score-badge ${scoreClass(row.score)}">${row.score}</span></td>
        <td><span class="score-status">${row.status}</span></td>
      </tr>
    `).join('');

    const average = Math.round(rows.reduce((sum, row) => sum + row.score, 0) / rows.length);
    const ready = rows.filter(row => row.status === 'Ready').length;

    document.getElementById('score-overall').textContent = `${average}%`;
    document.getElementById('score-blocking').textContent = '0';
    document.getElementById('score-products').textContent = String(ready);
    document.getElementById('score-coverage').textContent = '4 policies';
  }

  document.getElementById('score-run')?.addEventListener('click', render);
  render();
})();

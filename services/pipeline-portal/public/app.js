const qs = selector => document.querySelector(selector);
const qsa = selector => [...document.querySelectorAll(selector)];

const catalogBox = qs('#catalog');
const consoleBox = qs('#console');
const statusPill = qs('#jobStatus');

let activeJob = null;
let timer = null;
let activeFilter = 'all';
let catalogData = { apis: [], imported: [], mode: {} };
let selectedApiId = null;

const viewCopy = {
  backlog: {
    title: 'Pipeline backlog',
    subtitle: 'Validate API contracts, enforce telco governance, and import compliant APIs into APIM as working copies.'
  },
  console: {
    title: 'Execution console',
    subtitle: 'Watch the APIOps flow: contract checks, governance validation, APICTL dry-run and import-only onboarding.'
  },
  imported: {
    title: 'Imported APIs',
    subtitle: 'Review APIs already created in WSO2 API Manager by this pipeline run.'
  },
  proof: {
    title: 'Demo proof',
    subtitle: 'Use this section to explain what the pipeline proves to a technical telco audience.'
  }
};

async function loadCatalog() {
  const res = await fetch('/api/catalog');
  catalogData = await res.json();

  renderRuntime(catalogData.mode || {});
  renderKpis();
  renderCatalog();
  renderImported();

  if (!selectedApiId && catalogData.apis[0]) {
    selectedApiId = catalogData.apis[0].id;
  }

  renderSelected();
}

function renderRuntime(mode) {
  qs('#modeEffective').textContent = mode.effective || '--';
  qs('#apimReachable').textContent = mode.apimReachable ? 'online' : 'offline';
  qs('#apictlAvailable').textContent = mode.apictlAvailable ? 'installed' : 'missing';

  qs('#modeEffective').className = mode.effective === 'real' ? 'runtime-good' : 'runtime-warn';
  qs('#apimReachable').className = mode.apimReachable ? 'runtime-good' : 'runtime-bad';
  qs('#apictlAvailable').className = mode.apictlAvailable ? 'runtime-good' : 'runtime-bad';
}

function renderKpis() {
  const apis = catalogData.apis || [];
  const imported = catalogData.imported || [];

  const ready = apis.filter(api => api.governance?.approved).length;
  const rejected = apis.filter(api => !api.governance?.approved).length;

  qs('#kpiBacklog').textContent = apis.length;
  qs('#kpiReady').textContent = ready;
  qs('#kpiRejected').textContent = rejected;
  qs('#kpiImported').textContent = imported.filter(item => item.status === 'APPROVED_IMPORTED').length;
}

function renderCatalog() {
  const apis = catalogData.apis || [];
  let visible = apis;

  if (activeFilter === 'ready') {
    visible = apis.filter(api => api.governance?.approved);
  }

  if (activeFilter === 'violations') {
    visible = apis.filter(api => !api.governance?.approved);
  }

  if (!visible.length) {
    catalogBox.innerHTML = `
      <article class="empty-card">
        <h3>No APIs in this view</h3>
        <p>${apis.length ? 'Change the filter to see other API candidates.' : 'The pipeline backlog is empty. Use Reset backlog to make APIs selectable again for another demo run.'}</p>
      </article>
    `;
    return;
  }

  catalogBox.innerHTML = visible.map(api => apiCard(api)).join('');

  visible.forEach(api => {
    const card = document.getElementById(`card-${api.id}`);
    const runButton = document.getElementById(`run-${api.id}`);

    card.addEventListener('click', event => {
      if (event.target.closest('button')) return;
      selectedApiId = api.id;
      renderCatalog();
      renderSelected();
    });

    runButton.addEventListener('click', () => run(api.id));
  });
}

function apiCard(api) {
  const approved = Boolean(api.governance?.approved);
  const selected = selectedApiId === api.id;
  const findings = api.governance?.findings || [];
  const severity = approved ? 'approved' : 'rejected';

  return `
    <article id="card-${api.id}" class="api-card ${selected ? 'selected' : ''}">
      <div class="card-topline">
        <div>
          <span class="api-domain">${api.domain || 'API'}</span>
          <h3>${api.name}</h3>
        </div>
        <span class="score ${severity}">${api.governance?.score ?? '--'}</span>
      </div>

      <p>${api.description || 'No description provided.'}</p>

      <div class="badge-row">
        ${badge(approved ? 'Governance ready' : 'Governance violations', approved ? 'green' : 'red')}
        ${badge(api.protocol || 'REST', 'blue')}
        ${badge(api.contractType || 'OpenAPI', 'neutral')}
        ${badge(api.countryScope || 'regional', 'neutral')}
      </div>

      <div class="card-meta">
        <span><b>Owner</b>${api.owner || 'API Office'}</span>
        <span><b>Version</b>${api.version || '1.0.0'}</span>
        <span><b>Backend</b>${api.backendProtocol || api.protocol || 'HTTP'}</span>
      </div>

      ${findings.length ? `<div class="finding-summary">${findings.length} governance issue${findings.length > 1 ? 's' : ''} detected</div>` : ''}

      <button id="run-${api.id}" class="${approved ? 'run-button' : 'run-button warning'}">
        ${approved ? 'Run import pipeline' : 'Run rejection scenario'}
      </button>
    </article>
  `;
}

function renderSelected() {
  const api = (catalogData.apis || []).find(item => item.id === selectedApiId);
  const box = qs('#selectedApi');

  if (!api) {
    qs('#selectedTitle').textContent = 'No API selected';
    box.className = 'selected-empty';
    box.innerHTML = 'Select an API card to inspect the contract, governance score, artifacts and execution behavior.';
    return;
  }

  const approved = Boolean(api.governance?.approved);
  const findings = api.governance?.findings || [];
  qs('#selectedTitle').textContent = api.name;
  box.className = 'selected-detail';

  box.innerHTML = `
    <div class="selected-status ${approved ? 'green' : 'red'}">
      <strong>${approved ? 'Ready for import' : 'Rejected by governance'}</strong>
      <span>Governance score ${api.governance?.score ?? '--'}/100</span>
    </div>

    <div class="detail-section">
      <span class="mini-label">Artifact set</span>
      ${artifactLine('Main contract', api.spec)}
      ${api.importSpec ? artifactLine('APIM import façade', api.importSpec) : ''}
      ${api.supplementalSpec ? artifactLine('Supplemental contract', api.supplementalSpec) : ''}
    </div>

    <div class="detail-section">
      <span class="mini-label">Execution behavior</span>
      <p>${approved
        ? 'This API will run contract checks, governance validation, APICTL dry-run and import into APIM as a created working copy.'
        : 'This API intentionally fails governance. It should remain available in the backlog so the team can fix and resubmit it.'}</p>
    </div>

    <div class="detail-section">
      <span class="mini-label">Governance findings</span>
      ${findings.length
        ? findings.map(f => `<div class="finding ${severityClass(f.severity)}"><strong>${escapeHtml(f.ruleName)}</strong><span>${escapeHtml(f.message)}</span><small>${escapeHtml(f.violatedPath || '')}</small></div>`).join('')
        : '<div class="finding clean"><strong>No violations</strong><span>Mandatory metadata and contract checks are satisfied.</span></div>'}
    </div>
  `;
}

function artifactLine(label, value) {
  return `<div class="artifact-line"><span>${label}</span><code>${escapeHtml(value || '--')}</code></div>`;
}

function renderImported() {
  const imported = (catalogData.imported || []).filter(item => item.status === 'APPROVED_IMPORTED');
  const box = qs('#importedList');

  if (!imported.length) {
    box.innerHTML = `
      <article class="empty-card">
        <h3>No APIs imported yet</h3>
        <p>Run a compliant pipeline to create a working-copy API in APIM Publisher.</p>
      </article>
    `;
    return;
  }

  box.innerHTML = imported.map(item => `
    <article class="imported-card">
      <div class="card-topline">
        <div>
          <span class="api-domain">${item.protocol || 'API'} · ${item.contractType || 'OpenAPI'}</span>
          <h3>${item.name}</h3>
        </div>
        ${badge('Imported', 'green')}
      </div>
      <div class="card-meta">
        <span><b>Status</b>${item.status}</span>
        <span><b>Job</b>${item.jobId || '--'}</span>
        <span><b>Completed</b>${item.completedAt ? new Date(item.completedAt).toLocaleString() : '--'}</span>
      </div>
      <p>Created in APIM as a Publisher working copy. Not published and not deployed to the gateway.</p>
    </article>
  `).join('');
}

async function run(apiId) {
  setView('console');
  consoleBox.innerHTML = '';
  statusPill.textContent = 'Starting';
  statusPill.className = 'status-pill running';

  const res = await fetch('/api/pipeline/run', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ apiId })
  });

  const data = await res.json();

  if (!res.ok) {
    statusPill.textContent = 'Error';
    statusPill.className = 'status-pill error';
    consoleBox.innerHTML = logRow({
      ts: new Date().toISOString(),
      level: 'ERROR',
      message: data.error || 'Pipeline failed to start'
    });
    await loadCatalog();
    return;
  }

  activeJob = data.jobId;

  if (timer) clearInterval(timer);
  timer = setInterval(poll, 450);
  poll();
}

async function poll() {
  if (!activeJob) return;

  const res = await fetch(`/api/pipeline/jobs/${activeJob}`);
  const job = await res.json();

  statusPill.textContent = job.status;
  statusPill.className = `status-pill ${statusClass(job.status)}`;

  consoleBox.innerHTML = `
    <div class="job-summary">
      <div><span>Job</span><strong>${job.id}</strong></div>
      <div><span>API</span><strong>${job.name || job.apiId}</strong></div>
      <div><span>Started</span><strong>${new Date(job.startedAt).toLocaleTimeString()}</strong></div>
      <div><span>Status</span><strong>${job.status}</strong></div>
    </div>
    <div class="log-list">
      ${job.logs.map(logRow).join('')}
    </div>
  `;

  consoleBox.scrollTop = consoleBox.scrollHeight;

  if (!['RUNNING'].includes(job.status)) {
    clearInterval(timer);
    await loadCatalog();
  }
}

function logRow(log) {
  return `
    <div class="log ${log.level}">
      <span class="ts">${log.ts ? new Date(log.ts).toLocaleTimeString() : ''}</span>
      <span class="level">${escapeHtml(log.level || 'INFO')}</span>
      <span class="message">
        ${escapeHtml(log.message || '')}
        ${log.data ? `<code class="data">${escapeHtml(JSON.stringify(log.data))}</code>` : ''}
      </span>
    </div>
  `;
}

function setView(view) {
  qsa('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.view === view));
  qsa('.view').forEach(panel => panel.classList.toggle('active', panel.id === `view-${view}`));

  qs('#viewTitle').textContent = viewCopy[view].title;
  qs('#viewSubtitle').textContent = viewCopy[view].subtitle;
}

function badge(text, tone = 'neutral') {
  return `<span class="badge ${tone}">${escapeHtml(text)}</span>`;
}

function severityClass(severity) {
  const normalized = String(severity || '').toUpperCase();
  if (normalized === 'ERROR' || normalized === 'REJECTED' || normalized === 'CRITICAL') return 'red';
  if (normalized === 'WARN' || normalized === 'WARNING') return 'amber';
  return 'blue';
}

function statusClass(status) {
  if (status === 'RUNNING') return 'running';
  if (status === 'APPROVED_IMPORTED' || status === 'APPROVED_IMPORTED_SIMULATED') return 'success';
  if (status === 'REJECTED') return 'rejected';
  if (status === 'FAILED') return 'error';
  return 'neutral';
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[char]));
}

qsa('.nav-item').forEach(button => {
  button.addEventListener('click', () => setView(button.dataset.view));
});

qsa('.filter').forEach(button => {
  button.addEventListener('click', () => {
    activeFilter = button.dataset.filter;
    qsa('.filter').forEach(item => item.classList.toggle('active', item === button));
    renderCatalog();
  });
});

qs('#resetBacklog').addEventListener('click', async () => {
  const confirmed = window.confirm('Reset the pipeline backlog? This will make all APIs selectable again in the demo portal.');
  if (!confirmed) return;

  await fetch('/api/pipeline/reset', { method: 'POST' });

  activeJob = null;
  if (timer) clearInterval(timer);

  statusPill.textContent = 'Backlog reset';
  statusPill.className = 'status-pill neutral';

  consoleBox.innerHTML = logRow({
    ts: new Date().toISOString(),
    level: 'INFO',
    message: 'Pipeline backlog reset. All APIs are selectable again.'
  });

  selectedApiId = null;
  await loadCatalog();
});

qs('#refreshImported').addEventListener('click', loadCatalog);

loadCatalog().catch(error => {
  console.error(error);
  qs('#apimReachable').textContent = 'error';
  consoleBox.innerHTML = logRow({
    ts: new Date().toISOString(),
    level: 'ERROR',
    message: `Portal failed to initialize: ${error.message}`
  });
});

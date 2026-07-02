const express = require('express');
const morgan = require('morgan');
const fs = require('fs');
const path = require('path');
const { validate } = require('./governance');
const { createArtifact, commandPlan, executeRealImport, effectiveMode } = require('./apictl');
const ARTIFACTS_ROOT = process.env.ARTIFACTS_ROOT || '/workspace/artifacts';

const app = express();
const port = Number(process.env.PORT || 8090);
const artifactsRoot = process.env.ARTIFACTS_ROOT || process.env.ARTIFACTS_DIR || '/workspace/artifacts';
const stateRoot = process.env.STATE_ROOT || process.env.STATE_DIR || '/workspace/state';
const catalogPath = path.join(artifactsRoot, 'catalog.json');
const consumedPath = path.join(stateRoot, 'imported-apis.json');
const jobs = new Map();

app.use(morgan('tiny'));
app.use(express.json());
app.use(express.static('public'));

function ensureState() {
  fs.mkdirSync(stateRoot, { recursive: true });
  if (!fs.existsSync(consumedPath)) fs.writeFileSync(consumedPath, JSON.stringify({ imported: {} }, null, 2));
}

function catalog() {
  return JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
}

function consumed() {
  ensureState();
  try { return JSON.parse(fs.readFileSync(consumedPath, 'utf8')); }
  catch (_) { return { imported: {} }; }
}

function writeConsumed(data) {
  ensureState();
  fs.writeFileSync(consumedPath, JSON.stringify(data, null, 2));
}

function markConsumed(entry, job) {
  const data = consumed();
  data.imported[entry.id] = {
    id: entry.id,
    name: entry.name,
    status: job.status,
    jobId: job.id,
    protocol: entry.protocol,
    contractType: entry.contractType || 'OpenAPI',
    completedAt: new Date().toISOString()
  };
  writeConsumed(data);
}



app.get(['/api/soap-example/billing-adjustment-soap', '/api/soap-example/billing-adjustment'], (req, res) => {
  try {
    const examplePath = path.join(
      ARTIFACTS_ROOT,
      'contracts/soap/examples/billing-adjustment-create-request.xml'
    );

    if (!fs.existsSync(examplePath)) {
      res.status(404).json({
        error: 'BillingAdjustmentSOAP example file not found.',
        path: examplePath
      });
      return;
    }

    res.type('application/xml').send(fs.readFileSync(examplePath, 'utf8'));
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});


app.get('/api/soap-example/:id', (req, res) => {
  try {
    const catalogPath = path.join(ARTIFACTS_ROOT, 'catalog.json');
    const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
    const entry = (catalog.apis || []).find(api => api.id === req.params.id);

    if (!entry?.tryoutInstructions?.requestExample) {
      res.status(404).json({ error: 'SOAP example not found for this API.' });
      return;
    }

    const examplePath = path.join(ARTIFACTS_ROOT, entry.tryoutInstructions.requestExample);

    if (!fs.existsSync(examplePath)) {
      res.status(404).json({ error: 'SOAP example file not found.', path: entry.tryoutInstructions.requestExample });
      return;
    }

    res.type('application/xml').send(fs.readFileSync(examplePath, 'utf8'));
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});


app.get('/api/catalog', (req, res) => {
  const imported = consumed().imported || {};
  const entries = catalog().apis
    .filter(api => !imported[api.id])
    .map(api => {
      const result = validate(api, artifactsRoot);
      return { ...api, governance: result };
    });
  const mode = effectiveMode(process.env);
  res.json({ apis: entries, imported: Object.values(imported), mode });
});

app.get('/api/pipeline/imported', (req, res) => {
  res.json(consumed());
});

app.post('/api/pipeline/reset', (req, res) => {
  writeConsumed({ imported: {} });
  res.json({ ok: true, message: 'Pipeline backlog reset. All APIs are available again.' });
});

app.post('/api/pipeline/run', (req, res) => {
  const apiId = req.body.apiId;
  const imported = consumed().imported || {};
  if (imported[apiId]) return res.status(409).json({ error: 'API was already processed by the pipeline', imported: imported[apiId] });
  const entry = catalog().apis.find(a => a.id === apiId);
  if (!entry) return res.status(404).json({ error: 'API not found' });
  const jobId = `job-${Date.now()}-${Math.floor(Math.random() * 10000)}`;
  const job = { id: jobId, apiId, name: entry.name, status: 'RUNNING', startedAt: new Date().toISOString(), logs: [], result: null };
  jobs.set(jobId, job);
  runPipeline(job, entry);
  res.status(202).json({ jobId });
});

app.get('/api/pipeline/jobs/:id', (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) return res.status(404).json({ error: 'Job not found' });
  res.json(job);
});

function addLog(job, level, message, data) {
  job.logs.push({ ts: new Date().toISOString(), level, message, data });
}

function finish(job, entry, status, level, message) {
  job.status = status;
  addLog(job, level, message);
  // Per demo requirement: once a pipeline has run to a final business result, it disappears from the selectable backlog.
  // Failed technical imports stay available so the presenter can rerun after APIM becomes healthy.
  if (['APPROVED_IMPORTED'].includes(status)) {
    markConsumed(entry, job);
    addLog(job, 'INFO', 'Backlog updated: this API will no longer appear as selectable in the pipeline portal.');
  }
}

function schedule(job, delay, fn) {
  setTimeout(() => {
    try { fn(); } catch (e) {
      addLog(job, 'ERROR', e.message);
      job.status = 'FAILED';
      job.result = { approved: false, error: e.message };
    }
  }, delay);
}

function runPipeline(job, entry) {
  const stepMs = 560;
  schedule(job, 100, () => addLog(job, 'INFO', `Checkout API artifact: ${entry.spec}`));
  schedule(job, stepMs, () => {
    addLog(job, 'INFO', `Detect protocol: ${entry.protocol}${entry.backendProtocol ? ` backed by ${entry.backendProtocol}` : ''} · ${entry.name} ${entry.version || ''}`);
    addLog(job, 'INFO', `Contract set: ${entry.contractType || 'OpenAPI'}${entry.supplementalSpec ? ` · supplemental ${entry.supplementalSpec}` : ''}${entry.importSpec ? ` · APIM import façade ${entry.importSpec}` : ''}`);
  });
  schedule(job, stepMs * 2, () => addLog(job, 'INFO', 'Run contract linting and syntax checks'));
  schedule(job, stepMs * 3, () => addLog(job, 'INFO', 'Run telco governance rules: ownership, country scope, data classification, healthcheck, security, monetization'));

  schedule(job, stepMs * 4, () => {
    const result = validate(entry, artifactsRoot);
    job.result = result;
    if (result.findings.length === 0) addLog(job, 'PASS', `Governance score ${result.score}/100. No violations found.`);
    else result.findings.forEach(f => addLog(job, f.severity, `${f.ruleName}: ${f.message}`, { path: f.violatedPath }));
  });

  schedule(job, stepMs * 5, () => {
    if (!job.result || !job.result.approved) {
      finish(job, entry, 'REJECTED', 'REJECTED', 'API rejected before import. APICTL dry-run/import not executed because mandatory governance checks failed.');
      return;
    }
    const artifact = createArtifact(entry, artifactsRoot, stateRoot);
    job.artifact = artifact.zipPath;
    addLog(job, 'INFO', `Generated reviewed contract package: ${artifact.zipPath}`);
    const commands = commandPlan(entry, artifact.importSpecPath || artifact.targetDir, process.env);
    commands.slice(0, 4).forEach(cmd => addLog(job, 'CMD', cmd));
    addLog(job, 'PASS', 'APICTL dry-run gate prepared. API is compliant and can be imported.');
  });

  schedule(job, stepMs * 6, () => {
    if (job.status === 'REJECTED') return;
    const mode = effectiveMode(process.env);
    addLog(job, 'INFO', `APIM mode: configured=${mode.configured}, effective=${mode.effective}, apimReachable=${mode.apimReachable}, apictlAvailable=${mode.apictlAvailable}`);
    addLog(job, 'INFO', `APIM mode: configured=${mode.configured}, effective=${mode.effective}, apimReachable=${mode.apimReachable}, apictlAvailable=${mode.apictlAvailable}`);
    if (mode.apictlOutput) addLog(job, mode.apictlAvailable ? 'PASS' : 'ERROR', `apictl check: ${mode.apictlOutput}`);
    if (mode.apimOutput) addLog(job, mode.apimReachable ? 'PASS' : 'ERROR', `APIM check: ${mode.apimOutput}`);

    if (mode.effective !== 'real') {
      addLog(job, 'ERROR', 'Simulation mode is disabled for this demo flow. Set APIM_MODE=real and start APIM.');
      job.status = 'FAILED';
      return;
    }

    addLog(job, 'INFO', 'Executing APICTL against the configured APIM environment. Import creates/updates the Publisher working copy only. No publish and no gateway deployment.');
    try {
      const imported = executeRealImport(entry, artifactsRoot, stateRoot, process.env, msg => addLog(job, 'CMD', msg));
      job.projectDir = imported.projectDir;
      finish(job, entry, 'APPROVED_IMPORTED', 'PASS', 'API imported to APIM as CREATED/working-copy only. It was not published and no gateway revision was deployed.');
    } catch (e) {
      addLog(job, 'ERROR', `Real APICTL execution failed: ${e.message}`);
      addLog(job, 'INFO', 'The API remains available in the pipeline backlog because this was a technical import failure, not a governance decision.');
      job.status = 'FAILED';
    }
  });
}

ensureState();
app.listen(port, () => console.log(`Pipeline portal running on ${port}`));

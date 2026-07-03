const { execFileSync } = require('child_process');

function runCurlJson(args, log = console.log, okStatuses = [200, 201, 202, 204, 409]) {
  const out = execFileSync('curl', ['-k', '-sS', '-w', '\n%{http_code}', ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 20 * 1024 * 1024,
    timeout: 240000
  });

  const idx = out.lastIndexOf('\n');
  const body = idx >= 0 ? out.slice(0, idx) : out;
  const status = Number(idx >= 0 ? out.slice(idx + 1).trim() : 0);

  let data = null;
  try {
    data = body ? JSON.parse(body) : null;
  } catch {
    data = body;
  }

  if (!okStatuses.includes(status)) {
    throw new Error(`HTTP ${status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }

  return data;
}

function listPublisherLabels({ apimUrl, token, log }) {
  const result = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/labels`
  ], log, [200]);

  const labels = result?.list || result?.data || result?.labels || [];
  return Array.isArray(labels) ? labels : [];
}

function attachGovernanceLabels({ apimUrl, token, apiId, apiName, labels, log }) {
  const requested = Array.isArray(labels) ? labels.filter(Boolean) : [];

  if (!requested.length) {
    log(`Governance labels: no labels requested for ${apiName}.`);
    return;
  }

  const available = listPublisherLabels({ apimUrl, token, log });

  for (const labelName of requested) {
    const label = available.find(l => l.name === labelName || l.displayName === labelName);

    if (!label?.id) {
      log(`Governance labels: label not found in APIM: ${labelName}. Run governance-setup.js first.`);
      continue;
    }

    runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      '-H', 'Content-Type: application/json',
      '-d', JSON.stringify({ labels: [label.id] }),
      `${apimUrl}/api/am/publisher/v4/apis/${apiId}/attach-labels`
    ], log, [200, 201, 202, 409]);

    log(`Governance labels: attached "${labelName}" to ${apiName}.`);
  }
}

module.exports = { attachGovernanceLabels };


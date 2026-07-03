const fs = require('fs');
const { execFileSync } = require('child_process');

function runCurlJson(args, log = console.log, okStatuses = [200, 201, 202, 204]) {
  const out = execFileSync(
    'curl',
    ['-k', '-sS', '-w', '\n%{http_code}', ...args],
    {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 20 * 1024 * 1024,
      timeout: 240000
    }
  );

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

function findPublisherApi({ apimUrl, token, name, version, log }) {
  const query = encodeURIComponent(`name:${name}`);

  const result = runCurlJson([
    '-H',
    `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis?query=${query}&limit=100`
  ], log);

  const list = result?.list || result?.data || [];

  return list.find(api => api.name === name && (!api.version || api.version === version)) || null;
}

function deleteExistingApi({ apimUrl, token, name, version, log }) {
  const existing = findPublisherApi({ apimUrl, token, name, version, log });

  if (!existing?.id) {
    log(`Streaming import: no existing API to delete for ${name}:${version}`);
    return {
      deleted: false,
      existing: null,
      reason: 'not_found'
    };
  }

  log(`Streaming import: deleting existing API before recreation: ${name}:${version} (${existing.id}, type=${existing.type || 'unknown'})`);

  try {
    runCurlJson([
      '-X',
      'DELETE',
      '-H',
      `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis/${existing.id}`
    ], log, [200, 202, 204]);

    return {
      deleted: true,
      existing,
      reason: 'deleted'
    };
  } catch (e) {
    const message = String(e.message || '');

    if (message.includes('HTTP 409') && message.includes('active subscriptions')) {
      log(
        `Streaming import: existing API ${name}:${version} has active subscriptions; ` +
        `reusing it instead of deleting/recreating.`
      );

      return {
        deleted: false,
        existing,
        reason: 'active_subscriptions'
      };
    }

    throw e;
  }
}

function createRevisionAndDeploy({ apimUrl, token, apiId, log }) {
  log(`Streaming import: creating deployed revision for API ${apiId}`);

  const revision = runCurlJson([
    '-X',
    'POST',
    '-H',
    `Authorization: Bearer ${token}`,
    '-H',
    'Content-Type: application/json',
    '-d',
    JSON.stringify({
      description: 'Automated streaming API revision for local demo.'
    }),
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/revisions`
  ], log, [200, 201, 202]);

  const revisionId =
    revision?.id ||
    revision?.revisionUUID ||
    revision?.revisionId ||
    revision?.data?.id ||
    revision?.data?.revisionUUID ||
    revision?.data?.revisionId;

  if (!revisionId) {
    throw new Error(`Streaming import: revision creation did not return an id: ${JSON.stringify(revision)}`);
  }

  const payloadCandidates = [
    [
      {
        name: 'Default',
        vhost: 'localhost',
        displayOnDevportal: true
      }
    ],
    [
      {
        name: 'Default',
        deploymentEnvironment: 'Default',
        deploymentVhost: 'localhost',
        displayOnDevportal: true
      }
    ],
    [
      {
        deploymentEnvironment: 'Default',
        vhost: 'localhost',
        displayOnDevportal: true
      }
    ]
  ];

  let lastError = null;

  for (const payload of payloadCandidates) {
    try {
      runCurlJson([
        '-X',
        'POST',
        '-H',
        `Authorization: Bearer ${token}`,
        '-H',
        'Content-Type: application/json',
        '-d',
        JSON.stringify(payload),
        `${apimUrl}/api/am/publisher/v4/apis/${apiId}/deploy-revision?revisionId=${encodeURIComponent(revisionId)}`
      ], log, [200, 201, 202]);

      log(`Streaming import: deployed revision ${revisionId}`);
      return;
    } catch (e) {
      lastError = e;
      log(`Streaming import: deployment payload attempt failed: ${e.message}`);
    }
  }

  throw lastError || new Error('Streaming import: revision deployment failed.');
}

function publishApi({ apimUrl, token, apiId, log }) {
  try {
    runCurlJson([
      '-X',
      'POST',
      '-H',
      `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis/change-lifecycle?apiId=${encodeURIComponent(apiId)}&action=Publish`
    ], log, [200, 201, 202]);

    log('Streaming import: API published.');
  } catch (e) {
    const message = String(e.message || '');

    if (
      message.includes('already') ||
      message.includes('PUBLISHED') ||
      message.includes('Unsupported state change action')
    ) {
      log(`Streaming import: lifecycle publish skipped/non-fatal: ${message}`);
      return;
    }

    throw e;
  }
}

function importStreamingApi({
  apimUrl,
  token,
  name,
  version,
  context,
  asyncapiPath,
  endpointUrl,
  type = 'SSE',
  deleteExisting = true,
  deploy = true,
  publish = true,
  log = console.log
}) {
  if (!fs.existsSync(asyncapiPath)) {
    throw new Error(`Streaming import: AsyncAPI definition not found: ${asyncapiPath}`);
  }

  const normalizedType = String(type || 'SSE').toUpperCase();

  if (deleteExisting) {
    const deletion = deleteExistingApi({
      apimUrl,
      token,
      name,
      version,
      log
    });

    if (deletion?.reason === 'active_subscriptions' && deletion.existing?.id) {
      log(`Streaming import: reusing existing ${name}:${version} (${deletion.existing.id}) due to active subscriptions.`);

      if (publish) {
        publishApi({
          apimUrl,
          token,
          apiId: deletion.existing.id,
          log
        });
      }

      return deletion.existing;
    }
  }

  const additionalProperties = {
    name,
    version,
    context,
    type: normalizedType,
    transport: ['https'],
    visibility: 'PUBLIC',
    policies: ['Unlimited'],
    endpointImplementationType: 'ENDPOINT',
    endpointConfig: {
      endpoint_type: 'http',
      production_endpoints: {
        url: endpointUrl
      },
      sandbox_endpoints: {
        url: endpointUrl
      }
    }
  };

  log(`Streaming import: creating ${normalizedType} API through Publisher REST import-asyncapi.`);
  log(`Streaming import: ${name}:${version}`);
  log(`Streaming import: context=${context}`);
  log(`Streaming import: backend=${endpointUrl}`);
  log(`Streaming import: asyncapi=${asyncapiPath}`);

  const created = runCurlJson([
    '-X',
    'POST',
    '-H',
    `Authorization: Bearer ${token}`,
    '-F',
    `file=@${asyncapiPath};type=application/yaml`,
    '-F',
    `additionalProperties=${JSON.stringify(additionalProperties)}`,
    `${apimUrl}/api/am/publisher/v4/apis/import-asyncapi`
  ], log, [200, 201, 202]);

  const api = created?.data || created;

  if (!api?.id) {
    throw new Error(`Streaming import: APIM did not return an API id: ${JSON.stringify(created)}`);
  }

  if (api.type && String(api.type).toUpperCase() !== normalizedType) {
    throw new Error(`Streaming import: created API type is ${api.type}; expected ${normalizedType}. Response: ${JSON.stringify(api)}`);
  }

  if (deploy) {
    createRevisionAndDeploy({
      apimUrl,
      token,
      apiId: api.id,
      log
    });
  }

  if (publish) {
    publishApi({
      apimUrl,
      token,
      apiId: api.id,
      log
    });
  }

  log(`Streaming import: created ${name}:${version} as ${api.type || normalizedType} (${api.id})`);

  return api;
}

module.exports = {
  importStreamingApi
};

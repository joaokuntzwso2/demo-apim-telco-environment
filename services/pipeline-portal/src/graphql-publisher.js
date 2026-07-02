const fs = require('fs');
const { execFileSync } = require('child_process');

function runCurlJson(args, log = console.log, okStatuses = [200, 201, 202, 204]) {
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

function findPublisherApi({ apimUrl, token, name, version, log }) {
  const query = encodeURIComponent(`name:${name}`);

  const result = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis?query=${query}&limit=100`
  ], log);

  const list = result?.list || result?.data || [];
  return list.find(api => api.name === name && (!api.version || api.version === version)) || null;
}

function deleteExistingApi({ apimUrl, token, name, version, log }) {
  const existing = findPublisherApi({ apimUrl, token, name, version, log });

  if (!existing?.id) {
    log(`GraphQL import: no existing API to delete for ${name}:${version}`);
    return;
  }

  log(`GraphQL import: deleting existing API before recreation: ${name}:${version} (${existing.id}, type=${existing.type || 'unknown'})`);

  runCurlJson([
    '-X', 'DELETE',
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${existing.id}`
  ], log, [200, 202, 204]);
}

function validateGraphQLSchema({ apimUrl, token, schemaPath, log }) {
  log(`GraphQL import: validating SDL and extracting GraphQL operations.`);

  const validation = runCurlJson([
    '-X', 'POST',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `file=@${schemaPath};type=text/plain`,
    `${apimUrl}/api/am/publisher/v4/apis/validate-graphql-schema`
  ], log, [200, 201, 202]);

  if (validation?.isValid === false) {
    throw new Error(`GraphQL import: schema validation failed: ${validation.errorMessage || JSON.stringify(validation)}`);
  }

  const operations = validation?.graphQLInfo?.operations || [];

  if (!Array.isArray(operations) || operations.length === 0) {
    throw new Error(`GraphQL import: APIM validation did not extract GraphQL operations. Response: ${JSON.stringify(validation)}`);
  }

  log(`GraphQL import: extracted operations: ${operations.map(op => `${op.verb || 'OP'} ${op.target}`).join(', ')}`);

  return operations.map(op => ({
    target: op.target,
    verb: op.verb,
    authType: op.authType || 'Application & Application User',
    throttlingPolicy: op.throttlingPolicy || 'Unlimited',
    scopes: Array.isArray(op.scopes) ? op.scopes : [],
    operationPolicies: op.operationPolicies || { request: [], response: [], fault: [] }
  }));
}

function getApi({ apimUrl, token, apiId, log }) {
  return runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}`
  ], log, [200]);
}

function updateApiOperationsAndEndpoint({ apimUrl, token, apiId, operations, endpointUrl, log }) {
  const api = getApi({ apimUrl, token, apiId, log });

  api.operations = operations;
  api.endpointImplementationType = 'ENDPOINT';
  api.endpointConfig = {
    endpoint_type: 'http',
    production_endpoints: { url: endpointUrl },
    sandbox_endpoints: { url: endpointUrl }
  };

  log(`GraphQL import: updating API with ${operations.length} GraphQL operations before revision deployment.`);

  return runCurlJson([
    '-X', 'PUT',
    '-H', `Authorization: Bearer ${token}`,
    '-H', 'Content-Type: application/json',
    '-d', JSON.stringify(api),
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}`
  ], log, [200, 201, 202]);
}

function createRevisionAndDeploy({ apimUrl, token, apiId, log }) {
  log(`GraphQL import: creating deployed revision for API ${apiId}`);

  const revision = runCurlJson([
    '-X', 'POST',
    '-H', `Authorization: Bearer ${token}`,
    '-H', 'Content-Type: application/json',
    '-d', JSON.stringify({ description: 'Automated GraphQL API revision for local demo.' }),
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
    throw new Error(`GraphQL import: revision creation did not return an id: ${JSON.stringify(revision)}`);
  }

  const payloadCandidates = [
    [{ name: 'Default', vhost: 'localhost', displayOnDevportal: true }],
    [{ name: 'Default', deploymentEnvironment: 'Default', deploymentVhost: 'localhost', displayOnDevportal: true }],
    [{ deploymentEnvironment: 'Default', vhost: 'localhost', displayOnDevportal: true }]
  ];

  let lastError = null;

  for (const payload of payloadCandidates) {
    try {
      runCurlJson([
        '-X', 'POST',
        '-H', `Authorization: Bearer ${token}`,
        '-H', 'Content-Type: application/json',
        '-d', JSON.stringify(payload),
        `${apimUrl}/api/am/publisher/v4/apis/${apiId}/deploy-revision?revisionId=${encodeURIComponent(revisionId)}`
      ], log, [200, 201, 202]);

      log(`GraphQL import: deployed revision ${revisionId}`);
      return;
    } catch (e) {
      lastError = e;
      log(`GraphQL import: deployment payload attempt failed: ${e.message}`);
    }
  }

  throw lastError || new Error('GraphQL import: revision deployment failed.');
}

function publishApi({ apimUrl, token, apiId, log }) {
  try {
    runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis/change-lifecycle?apiId=${encodeURIComponent(apiId)}&action=Publish`
    ], log, [200, 201, 202]);

    log(`GraphQL import: API published.`);
  } catch (e) {
    if (String(e.message || '').includes('already') || String(e.message || '').includes('PUBLISHED')) {
      log(`GraphQL import: API already published.`);
      return;
    }
    throw e;
  }
}

function importGraphQLApi({
  apimUrl,
  token,
  name,
  version,
  context,
  schemaPath,
  endpointUrl,
  deleteExisting = true,
  deploy = false,
  publish = false,
  log = console.log
}) {
  if (!fs.existsSync(schemaPath)) {
    throw new Error(`GraphQL import: SDL schema not found: ${schemaPath}`);
  }

  const operations = validateGraphQLSchema({ apimUrl, token, schemaPath, log });

  if (deleteExisting) {
    deleteExistingApi({ apimUrl, token, name, version, log });
  }

  const additionalProperties = {
    name,
    version,
    context,
    type: 'GRAPHQL',
    transport: ['https'],
    visibility: 'PUBLIC',
    policies: ['Unlimited'],
    operations,
    endpointImplementationType: 'ENDPOINT',
    endpointConfig: {
      endpoint_type: 'http',
      production_endpoints: { url: endpointUrl },
      sandbox_endpoints: { url: endpointUrl }
    }
  };

  log(`GraphQL import: creating GRAPHQL API through Publisher REST import-graphql-schema.`);
  log(`GraphQL import: ${name}:${version}`);
  log(`GraphQL import: context=${context}`);
  log(`GraphQL import: backend=${endpointUrl}`);
  log(`GraphQL import: schema=${schemaPath}`);

  const created = runCurlJson([
    '-X', 'POST',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `file=@${schemaPath};type=text/plain`,
    '-F', `additionalProperties=${JSON.stringify(additionalProperties)}`,
    `${apimUrl}/api/am/publisher/v4/apis/import-graphql-schema`
  ], log, [200, 201, 202]);

  const api = created?.data || created;

  if (!api?.id) {
    throw new Error(`GraphQL import: APIM did not return an API id: ${JSON.stringify(created)}`);
  }

  if (api.type && String(api.type).toUpperCase() !== 'GRAPHQL') {
    throw new Error(`GraphQL import: created API type is ${api.type}; expected GRAPHQL. Response: ${JSON.stringify(api)}`);
  }

  updateApiOperationsAndEndpoint({
    apimUrl,
    token,
    apiId: api.id,
    operations,
    endpointUrl,
    log
  });

  if (deploy) {
    createRevisionAndDeploy({ apimUrl, token, apiId: api.id, log });
  }

  if (publish) {
    publishApi({ apimUrl, token, apiId: api.id, log });
  }

  log(`GraphQL import: created unpublished working copy ${name}:${version} as ${api.type || 'GRAPHQL'} (${api.id})`);

  return api;
}

module.exports = { importGraphQLApi };


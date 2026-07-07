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

  return { status, data };
}

function findPublisherApiIfExists(apimUrl, token, name, version, log = console.log, context = '') {
  function queryApis(query = '') {
    const queryPart = query ? `query=${encodeURIComponent(query)}&` : '';
    const res = runCurlJson([
      '-H', `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis?${queryPart}limit=100&offset=0`
    ], log);
    return res.data?.list || res.data?.data || [];
  }

  const seen = new Map();
  const queries = [name, `name:${name}`, context, context ? `context:${context}` : '', ''];
  for (const query of queries) {
    if (query === '' || query) {
      for (const api of queryApis(query)) {
        if (api?.id) seen.set(api.id, api);
      }
    }
  }

  for (const summary of seen.values()) {
    let full = summary;
    try {
      full = runCurlJson([
        '-H', `Authorization: Bearer ${token}`,
        `${apimUrl}/api/am/publisher/v4/apis/${summary.id}`
      ], log).data || summary;
    } catch (err) {
      log(`Non-fatal full API lookup failure for ${summary.id}: ${err.message || err}`);
    }

    const versionMatches = !full.version || full.version === version;
    const nameMatches = full.name === name;
    const contextMatches = Boolean(context) && full.context === context;
    if (versionMatches && (nameMatches || contextMatches)) return full;
  }

  return null;
}
function deleteLegacyApiIfPossible(apimUrl, token, name, version, log = console.log) {
  const existing = findPublisherApiIfExists(apimUrl, token, name, version, log);

  if (!existing?.id) {
    log(`No existing API to delete for ${name}:${version}`);
    return null;
  }

  if (String(existing.type || '').toUpperCase() === 'SOAP') {
    log(`Existing SOAP API found: ${name}:${version} (${existing.id}). Reusing it instead of deleting.`);
    return existing;
  }

  log(`Deleting existing non-SOAP/legacy API before SOAP recreation: ${name}:${version} (${existing.id}, type=${existing.type || 'unknown'})`);

  try {
    runCurlJson([
      '-X', 'DELETE',
      '-H', `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis/${existing.id}`
    ], log, [200, 202, 204]);

    return null;
  } catch (err) {
    if (String(err.message || err).includes('HTTP 409')) {
      log(`Existing API ${name}:${version} has active subscriptions; reusing it instead of deleting.`);
      return existing;
    }

    throw err;
  }
}

function soapTryoutSample() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:bil="http://demo.telco.wso2.com/billing">
  <soapenv:Header/>
  <soapenv:Body>
    <bil:CreateBillingAdjustmentRequest>
      <bil:msisdn>+5511999990001</bil:msisdn>
      <bil:amount>12.50</bil:amount>
      <bil:currency>BRL</bil:currency>
      <bil:reasonCode>DEMO_CREDIT</bil:reasonCode>
      <bil:requestor>apim-publisher-demo</bil:requestor>
    </bil:CreateBillingAdjustmentRequest>
  </soapenv:Body>
</soapenv:Envelope>`;
} function soapBodySchema(sample) {
  return {
    type: 'string',
    format: 'xml',
    default: sample,
    example: sample,
    'x-example': sample,
    xml: {
      name: 'Envelope',
      namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
      prefix: 'soapenv'
    }
  };
}

function soapActionHeaderParameter(action) {
  const quotedAction = `"${action}"`;
  return {
    name: 'SOAPAction',
    in: 'header',
    description: 'SOAPAction header for SOAP 1.1.',
    required: true,
    type: 'string',
    default: quotedAction,
    enum: [quotedAction]
  };
}

function patchSoapTryoutExample({ apimUrl, token, apiId, log = console.log }) {
  const sample = soapTryoutSample();

  log(`Patching SOAP DevPortal Try Out example for API ${apiId}`);

  const swagger = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/swagger`
  ], log).data;

  if (!swagger || typeof swagger !== 'object') {
    log(`Skipping SOAP Try Out patch because Swagger/OpenAPI definition could not be parsed.`);
    return;
  }

  if (swagger.swagger) {
    swagger.consumes = ['text/xml', 'application/xml'];
    swagger.produces = ['text/xml', 'application/xml'];

    for (const pathItem of Object.values(swagger.paths || {})) {
      for (const [method, operation] of Object.entries(pathItem || {})) {
        if (!['post', 'put'].includes(method.toLowerCase())) continue;

        operation.summary = operation.summary || 'Invoke SOAP operation';
        operation.description = 'Paste a SOAP envelope and invoke the SOAP pass-through API.';
        operation.consumes = ['text/xml', 'application/xml'];
        operation.produces = ['text/xml', 'application/xml'];
        operation.parameters = Array.isArray(operation.parameters) ? operation.parameters : [];

        let body = operation.parameters.find(p => p.in === 'body');
        if (!body) {
          body = {
            name: 'SOAP Request',
            in: 'body',
            required: true,
            description: 'SOAP request envelope.',
            schema: { type: 'string' }
          };
          operation.parameters.unshift(body);
        }

        body.name = 'SOAP Request';
body.description = 'SOAP request envelope.';
body.required = true;
body.schema = soapBodySchema(sample);
body['x-example'] = sample;
body['x-examples'] = {
  'text/xml': sample,
  'application/xml': sample
};
operation['x-examples'] = {
  'text/xml': sample,
  'application/xml': sample
};

if (Array.isArray(operation.parameters)) {
  operation.parameters = operation.parameters.filter(p => p.name !== 'SOAPAction');
  operation.parameters.unshift(soapActionHeaderParameter('CreateBillingAdjustment'));
}
      }
    }
  } else if (swagger.openapi) {
    for (const pathItem of Object.values(swagger.paths || {})) {
      for (const [method, operation] of Object.entries(pathItem || {})) {
        if (!['post', 'put'].includes(method.toLowerCase())) continue;

        operation.summary = operation.summary || 'Invoke SOAP operation';
        operation.description = 'Paste a SOAP envelope and invoke the SOAP pass-through API.';
        operation.requestBody = {
  required: true,
  content: {
    'text/xml': {
      schema: soapBodySchema(sample),
      example: sample,
      examples: {
        default: {
          summary: 'SOAP request envelope',
          value: sample
        }
      }
    },
    'application/xml': {
      schema: soapBodySchema(sample),
      example: sample,
      examples: {
        default: {
          summary: 'SOAP request envelope',
          value: sample
        }
      }
    }
  }
};
      }
    }
  }

  const patchedFile = `/tmp/${apiId}-soap-tryout-swagger.json`;
  fs.writeFileSync(patchedFile, JSON.stringify(swagger, null, 2));

  runCurlJson([
    '-X', 'PUT',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `apiDefinition=@${patchedFile};type=application/json`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/swagger`
  ], log);

  log(`SOAP DevPortal Try Out example patched for API ${apiId}`);
}

function changeLifecycleIfNeeded(apimUrl, token, apiId, action, log = console.log) {
  try {
    runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis/change-lifecycle?apiId=${apiId}&action=${encodeURIComponent(action)}`
    ], log, [200, 201, 202]);

    log(`Lifecycle action completed: ${action} for API ${apiId}`);
  } catch (err) {
    const message = String(err.message || err);

    if (
      message.includes('already') ||
      message.includes('not allowed') ||
      message.includes('lifecycle')
    ) {
      log(`Non-fatal lifecycle action issue for ${apiId}: ${message}`);
      return;
    }

    throw err;
  }
}

function createAndDeployRevision(apimUrl, token, apiId, log = console.log) {
  try {
    const revision = runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      '-H', 'Content-Type: application/json',
      '-d', JSON.stringify({
        description: `Automated demo deployment revision ${new Date().toISOString()}`
      }),
      `${apimUrl}/api/am/publisher/v4/apis/${apiId}/revisions`
    ], log, [200, 201, 202]).data;

    const revisionId = revision?.id;
    if (!revisionId) {
      log(`Revision creation did not return an id for API ${apiId}. Response: ${JSON.stringify(revision)}`);
      return;
    }

    log(`Created revision ${revisionId} for API ${apiId}`);

    runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      '-H', 'Content-Type: application/json',
      '-d', JSON.stringify([
        {
          name: 'Default',
          vhost: 'localhost',
          displayOnDevportal: true
        }
      ]),
      `${apimUrl}/api/am/publisher/v4/apis/${apiId}/deploy-revision?revisionId=${revisionId}`
    ], log, [200, 201, 202]);

    log(`Deployed revision ${revisionId} for API ${apiId}`);
  } catch (err) {
    const message = String(err.message || err);

    if (
      message.includes('maximum number of revisions') ||
      message.includes('already deployed') ||
      message.includes('HTTP 409')
    ) {
      log(`Non-fatal revision/deployment issue for API ${apiId}: ${message}`);
      return;
    }

    throw err;
  }
}

function createSoapPassThroughApi({
  apimUrl,
  token,
  name,
  version,
  context,
  wsdlPath,
  endpointUrl,
  publish = true,
  deploy = true,
  deleteExisting = false,
  legacyNamesToDelete = [],
  log = console.log
}) {
  if (!apimUrl) throw new Error('apimUrl is required.');
  if (!token) throw new Error('token is required.');
  if (!name) throw new Error('SOAP API name is required.');
  if (!version) throw new Error('SOAP API version is required.');
  if (!context) throw new Error('SOAP API context is required.');
  if (!wsdlPath) throw new Error('wsdlPath is required.');
  if (!endpointUrl) throw new Error('endpointUrl is required.');

  if (!fs.existsSync(wsdlPath)) {
    throw new Error(`SOAP WSDL not found: ${wsdlPath}`);
  }

  // Runtime SOAP APIs are idempotent. If the API already exists as SOAP,
  // reuse it because APIM blocks deletion once subscriptions exist.
  const existingSoapApi = findPublisherApiIfExists(apimUrl, token, name, version, log, context);

  if (
    existingSoapApi &&
    existingSoapApi.id &&
    String(existingSoapApi.type || '').toUpperCase() === 'SOAP'
  ) {
    log(`Reusing existing SOAP API instead of deleting/recreating: ${name}:${version} (${existingSoapApi.id})`);

    try {
      patchSoapTryoutExample({ apimUrl, token, apiId: existingSoapApi.id, log });
    } catch (err) {
      log(`Non-fatal SOAP Try Out patch failure while reusing existing API: ${err.message || err}`);
    }

    if (deploy) {
      log(`Skipping revision creation for reused SOAP API ${name}:${version}; existing deployment is kept to avoid APIM revision-limit churn.`);
    }

    if (publish) {
      changeLifecycleIfNeeded(apimUrl, token, existingSoapApi.id, 'Publish', log);
    }

    return {
      id: existingSoapApi.id,
      apiId: existingSoapApi.id,
      name: existingSoapApi.name || name,
      version: existingSoapApi.version || version,
      type: existingSoapApi.type || 'SOAP',
      context: existingSoapApi.context || context,
      lifeCycleStatus: existingSoapApi.lifeCycleStatus,
      reused: true
    };
  }

  if (deleteExisting) {
    for (const oldName of [name, ...legacyNamesToDelete]) {
      deleteLegacyApiIfPossible(apimUrl, token, oldName, version, log);
    }
  }

  const additionalProperties = {
    name,
    version,
    context,
    type: 'SOAP',
    transport: ['https'],
    visibility: 'PUBLIC',
    policies: ['Unlimited'],
    endpointConfig: {
      endpoint_type: 'http',
      production_endpoints: { url: endpointUrl },
      sandbox_endpoints: { url: endpointUrl }
    }
  };

  log(`Creating TRUE SOAP pass-through API from WSDL: ${name}:${version}`);
  log(`implementationType=SOAP`);
  log(`context=${context}`);
  log(`endpoint=${endpointUrl}`);
  log(`wsdl=${wsdlPath}`);

  // Validate Publisher token before import-wsdl.
  runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis?limit=1`
  ], log);

  let imported;
try {
  imported = runCurlJson([
    '-X', 'POST',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `file=@${wsdlPath};type=text/xml`,
    '-F', `additionalProperties=${JSON.stringify(additionalProperties)}`,
    '-F', 'implementationType=SOAP',
    `${apimUrl}/api/am/publisher/v4/apis/import-wsdl`
  ], log);
} catch (err) {
  const message = String(err.message || err);
  if (!message.includes('HTTP 409')) throw err;

  const existingAfterConflict = findPublisherApiIfExists(
    apimUrl, token, name, version, log, context
  );
  if (!existingAfterConflict?.id) {
    throw new Error(
      `SOAP import returned HTTP 409, but no existing API could be resolved by ` +
      `name=${name}, version=${version}, context=${context}. Original error: ${message}`
    );
  }

  log(
    `SOAP import returned HTTP 409; reusing existing API: ` +
    `${existingAfterConflict.name || name}:${existingAfterConflict.version || version} ` +
    `(${existingAfterConflict.id}) context=${existingAfterConflict.context || context} ` +
    `type=${existingAfterConflict.type || 'unknown'}`
  );

  try {
    patchSoapTryoutExample({
      apimUrl,
      token,
      apiId: existingAfterConflict.id,
      log
    });
  } catch (patchErr) {
    log(`Non-fatal SOAP Try Out patch failure after 409 recovery: ${patchErr.message || patchErr}`);
  }

  if (publish) {
    changeLifecycleIfNeeded(apimUrl, token, existingAfterConflict.id, 'Publish', log);
  }

  return {
    id: existingAfterConflict.id,
    apiId: existingAfterConflict.id,
    name: existingAfterConflict.name || name,
    version: existingAfterConflict.version || version,
    type: existingAfterConflict.type || 'SOAP',
    context: existingAfterConflict.context || context,
    lifeCycleStatus: existingAfterConflict.lifeCycleStatus,
    reused: true,
    recoveredFromConflict: true
  };
}
const created = imported.data || {};
  const apiId = created.id;

  if (!apiId) {
    throw new Error(`SOAP import did not return an API id: ${JSON.stringify(created)}`);
  }

  if (created.type && String(created.type).toUpperCase() !== 'SOAP') {
    throw new Error(`Created API type is ${created.type}; expected SOAP. Response: ${JSON.stringify(created)}`);
  }

  log(`Created SOAP API in Publisher: ${name}:${version} (${apiId}) type=${created.type || 'SOAP'}`);

  try {
    patchSoapTryoutExample({ apimUrl, token, apiId, log });
  } catch (err) {
    log(`Non-fatal SOAP Try Out patch failure: ${err.message || err}`);
  }

  if (deploy) {
    createAndDeployRevision(apimUrl, token, apiId, log);
  }

  if (publish) {
    changeLifecycleIfNeeded(apimUrl, token, apiId, 'Publish', log);
  }

  return {
    id: apiId,
    apiId,
    name: created.name || name,
    version: created.version || version,
    type: created.type || 'SOAP',
    context: created.context || context,
    lifeCycleStatus: created.lifeCycleStatus,
    reused: false
  };
}

module.exports = {
  createSoapPassThroughApi
};

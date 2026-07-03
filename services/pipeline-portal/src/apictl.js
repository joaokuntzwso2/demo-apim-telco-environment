const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const AdmZip = require('adm-zip');
const YAML = require('yaml'); const { importStreamingApi } = require('./streaming-publisher'); const { importGraphQLApi } = require('./graphql-publisher');

function safeName(name) {
  return name.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '');
}

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, 'utf8'));
}

function writeYaml(file, value) {
  fs.writeFileSync(file, YAML.stringify(value));
}

function createArtifact(entry, artifactsRoot, stateRoot) {
  const generatedRoot = path.join(stateRoot, 'generated');
  const targetDir = path.join(generatedRoot, `${safeName(entry.name)}-${entry.version || '1.0.0'}`);

  fs.rmSync(targetDir, { recursive: true, force: true });
  fs.mkdirSync(targetDir, { recursive: true });

  const mainSpecPath = path.join(artifactsRoot, entry.spec);
  const importSpecRel = entry.importSpec || entry.spec;
  const importSpecPath = path.join(artifactsRoot, importSpecRel);

  fs.copyFileSync(mainSpecPath, path.join(targetDir, path.basename(mainSpecPath)));

  if (importSpecPath !== mainSpecPath && fs.existsSync(importSpecPath)) {
    fs.copyFileSync(importSpecPath, path.join(targetDir, path.basename(importSpecPath)));
  }

  if (entry.supplementalSpec) {
    const supplementalPath = path.join(artifactsRoot, entry.supplementalSpec);
    if (fs.existsSync(supplementalPath)) {
      fs.copyFileSync(supplementalPath, path.join(targetDir, path.basename(supplementalPath)));
    }
  }

  fs.writeFileSync(path.join(targetDir, 'deployment-manifest.json'), JSON.stringify({
    name: entry.name,
    version: entry.version || '1.0.0',
    protocol: entry.protocol,
    backendProtocol: entry.backendProtocol || entry.protocol,
    contractType: entry.contractType || 'OpenAPI',
    generatedAt: new Date().toISOString(),
    apimImportOnly: true,
    publish: false,
    deployRevision: false,
    governanceSpec: entry.spec,
    importSpec: importSpecRel,
    supplementalSpec: entry.supplementalSpec || null
  }, null, 2));

  const zipPath = `${targetDir}.zip`;
  const zip = new AdmZip();
  zip.addLocalFolder(targetDir);
  zip.writeZip(zipPath);

  return { targetDir, zipPath, importSpecPath };
}

function commandPlan(entry, artifactPath, env) {
  if (
    entry.protocol === 'GRAPHQL' ||
    entry.type === 'GRAPHQL' ||
    /GraphQL/i.test(entry.contractType || '') ||
    /\.graphql$/i.test(entry.spec || '')
  ) {
    const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
    return [
      `curl -k -H "Authorization: Bearer <publisher-token>" -F file=@${entry.spec} -F additionalProperties=@graphql-api.json ${apimUrl}/api/am/publisher/v4/apis/import-graphql-schema`,
      `keep ${entry.name} as Publisher working copy; no revision deployment`,
      `do not publish ${entry.name}; lifecycle remains pre-published`
    ];
  }


  const insecure = env.APIM_INSECURE_TLS === 'true' ? ' -k' : '';
  const apimEnv = env.APIM_ENV || 'am47';
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const source = entry.importSpec ? `${entry.spec} + import façade ${entry.importSpec}` : entry.spec;

  return [
    `apictl version`,
    `apictl add env ${apimEnv} --apim ${apimUrl} --token ${apimUrl}/oauth2/token${insecure}`,
    `apictl login ${apimEnv} -u ${env.APIM_USERNAME || 'admin'} -p ********${insecure}`,
    `apictl init ${safeName(entry.name)} --oas ${source} --definition definition.yaml --force=true`,
    `apictl import api --file ${artifactPath} --environment ${apimEnv} --dry-run${insecure}`,
    `apictl import api --file ${artifactPath} --environment ${apimEnv} --update=true --skip-deployments${insecure}`
  ];
}

function apictlStatus() {
  try {
    const out = execFileSync('apictl', ['version'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    return { available: true, output: out.trim() };
  } catch (e) {
    return { available: false, output: e.stderr?.toString?.() || e.message };
  }
}

function apimStatus(env) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  try {
    const out = execFileSync('curl', ['-k', '-f', '-sS', '--connect-timeout', '5', `${apimUrl}/services/Version`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    return { reachable: true, output: out.trim() };
  } catch (e) {
    return { reachable: false, output: e.stderr?.toString?.() || e.message };
  }
}

function effectiveMode(env) {
  const configured = env.APIM_MODE || 'real';
  const apim = apimStatus(env);
  const cli = apictlStatus();

  return {
    configured,
    effective: configured === 'simulate' ? 'simulate' : 'real',
    apimReachable: apim.reachable,
    apictlAvailable: cli.available,
    apimOutput: apim.output,
    apictlOutput: cli.output
  };
}


function runCurlJson(args, log, okStatuses = [200, 201, 202, 204]) {
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
  try { data = body ? JSON.parse(body) : null; }
  catch { data = body; }

  if (!okStatuses.includes(status)) {
    throw new Error(`HTTP ${status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }

  return { status, data };
}

function getPublisherTokenForSoap(env, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const username = env.APIM_USERNAME || 'admin';
  const password = env.APIM_PASSWORD || 'admin';

  log(`SOAP import: registering temporary Publisher REST client`);

  const dcr = runCurlJson([
    '-X', 'POST',
    '-u', `${username}:${password}`,
    '-H', 'Content-Type: application/json',
    '-d', JSON.stringify({
      callbackUrl: 'http://localhost:8090/callback',
      clientName: `pipeline-soap-import-${Date.now()}`,
      owner: username,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    }),
    `${apimUrl}/client-registration/v0.17/register`
  ], log);

  const token = runCurlJson([
    '-X', 'POST',
    '-u', `${dcr.data.clientId}:${dcr.data.clientSecret}`,
    '-H', 'Content-Type: application/x-www-form-urlencoded',
    '--data-urlencode', 'grant_type=password',
    '--data-urlencode', `username=${username}`,
    '--data-urlencode', `password=${password}`,
    '--data-urlencode', 'scope=apim:api_view apim:api_create apim:api_manage apim:api_publish apim:api_import_export apim:api_delete apim:api_update apim:label_view apim:label_manage apim:label_update apim:label_view apim:label_manage apim:label_update apim:api_definition_view apim:api_definition_update',
    `${apimUrl}/oauth2/token`
  ], log);

  return token.data.access_token;
}

  
function requestedGovernanceLabels(entry) {
  return Array.isArray(entry.governanceLabels)
    ? entry.governanceLabels.filter(Boolean)
    : [];
}

function listPublisherLabelsForPipeline(env, token, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  const result = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/labels`
  ], log, [200]);

  const labels =
    result.data?.list ||
    result.data?.data ||
    result.data?.labels ||
    result.data ||
    [];

  return Array.isArray(labels) ? labels : [];
}

function listPublisherApisForPipeline(env, token, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  const result = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis?limit=1000`
  ], log, [200]);

  const apis =
    result.data?.list ||
    result.data?.data ||
    result.data?.apis ||
    result.data ||
    [];

  return Array.isArray(apis) ? apis : [];
}

function findPublisherApiForPipelineEntry(env, token, entry, log) {
  const expectedName = entry.name;
  const expectedVersion = entry.version || '1.0.0';
  const expectedContext = entry.context;

  for (let attempt = 1; attempt <= 20; attempt += 1) {
    const apis = listPublisherApisForPipeline(env, token, log);

    const exact = apis.find(api =>
      api.name === expectedName &&
      (!api.version || api.version === expectedVersion)
    );

    if (exact) {
      return exact;
    }

    if (expectedContext) {
      const byContext = apis.find(api =>
        api.context === expectedContext &&
        (!api.version || api.version === expectedVersion)
      );

      if (byContext) {
        return byContext;
      }
    }

    if (attempt === 1 || attempt % 5 === 0) {
      const visibleCandidates = apis
        .filter(api => String(api.name || '').includes('Candidate'))
        .map(api => `${api.name}:${api.version || 'unknown'}:${api.type || 'unknown'}`)
        .join(', ');

      log(`Governance labels: waiting for ${expectedName} to appear in Publisher. Attempt ${attempt}/20. Current candidates: ${visibleCandidates || 'none'}`);
    }

    require('child_process').execFileSync('sh', ['-c', 'sleep 1'], {
      stdio: ['ignore', 'ignore', 'ignore']
    });
  }

  return null;
}

function attachPipelineGovernanceLabels(env, token, apiId, entry, log) {
  const wanted = requestedGovernanceLabels(entry);

  if (!wanted.length) {
    log(`Governance labels: no labels requested for ${entry.name}.`);
    return;
  }

  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const available = listPublisherLabelsForPipeline(env, token, log);

  for (const labelName of wanted) {
    const label = available.find(l =>
      l.name === labelName ||
      l.displayName === labelName
    );

    if (!label?.id) {
      log(`Governance labels: "${labelName}" not found in APIM. Run governance-setup.js first.`);
      continue;
    }

    runCurlJson([
      '-X', 'POST',
      '-H', `Authorization: Bearer ${token}`,
      '-H', 'Content-Type: application/json',
      '-d', JSON.stringify({ labels: [label.id] }),
      `${apimUrl}/api/am/publisher/v4/apis/${apiId}/attach-labels`
    ], log, [200, 201, 202, 409]);

    log(`Governance labels: attached "${labelName}" to ${entry.name}.`);
  }
}

function attachPipelineGovernanceLabelsByEntry(env, token, entry, log) {
  const api = findPublisherApiForPipelineEntry(env, token, entry, log);

  if (!api?.id) {
    log(`Governance labels: imported API not found in Publisher for ${entry.name}.`);
    return;
  }

  attachPipelineGovernanceLabels(env, token, api.id, entry, log);
}


function findPublisherApiForSoap(env, token, name, version, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const query = encodeURIComponent(`name:${name}`);

  const res = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis?query=${query}&limit=100`
  ], log);

  const list = res.data?.list || res.data?.data || [];
  return list.find(api => api.name === name && (!api.version || api.version === version)) || null;
}


function pipelineGovernanceLabels(entry) {
  return Array.isArray(entry.governanceLabels)
    ? entry.governanceLabels.filter(Boolean)
    : [];
}

function listApimLabelsForPipeline(env, token, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  const res = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/admin/v4/labels`
  ], log, [200]);

  const labels =
    res.data?.list ||
    res.data?.data ||
    res.data?.labels ||
    res.data ||
    [];

  return Array.isArray(labels) ? labels : [];
}

 

function deletePublisherApiForSoapIfExists(env, token, name, version, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const existing = findPublisherApiForSoap(env, token, name, version, log);

  if (!existing?.id) {
    log(`SOAP import: no existing API to delete for ${name}:${version}`);
    return;
  }

  log(`SOAP import: deleting existing API before recreation: ${name}:${version} (${existing.id}, type=${existing.type || 'unknown'})`);

  runCurlJson([
    '-X', 'DELETE',
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${existing.id}`
  ], log, [200, 202, 204]);
}


function soapApimReachable(env) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  try {
    execFileSync('curl', ['-k', '-sS', '-f', `${apimUrl}/services/Version`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 30000
    });
    return true;
  } catch {
    return false;
  }
}


function soapTryoutSample() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:wor="http://demo.telco.wso2.com/workorder">
  <soapenv:Header/>
  <soapenv:Body>
    <wor:CreateWorkOrderRequest>
      <wor:customerId>CUST-10001</wor:customerId>
      <wor:siteId>BR-SP-EDGE-03</wor:siteId>
      <wor:priority>HIGH</wor:priority>
      <wor:description>Field technician required for site inspection.</wor:description>
    </wor:CreateWorkOrderRequest>
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


function ensureCandidateSoapActionHeader(operation) {
  operation.parameters = Array.isArray(operation.parameters) ? operation.parameters : [];

  let header = operation.parameters.find(p =>
    p.in === 'header' &&
    String(p.name || '').toLowerCase() === 'soapaction'
  );

  if (!header) {
    header = {
      name: 'SOAPAction',
      in: 'header',
      required: false,
      type: 'string',
      default: 'CreateWorkOrder',
      description: 'SOAP 1.1 action header.'
    };
    operation.parameters.unshift(header);
  } else {
    header.name = 'SOAPAction';
    header.in = 'header';
    header.required = false;
    header.type = header.type || 'string';
    header.default = 'CreateWorkOrder';
    header.description = header.description || 'SOAP 1.1 action header.';
  }
}


function patchSoapTryoutExample(env, token, apiId, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const sample = soapTryoutSample();

  log(`SOAP import: patching DevPortal Try Out example for API ${apiId}`);

  const swagger = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/swagger`
  ], log).data;

  if (swagger.swagger) {
    swagger.consumes = ['text/xml', 'application/xml'];
    swagger.produces = ['text/xml', 'application/xml'];

    for (const pathItem of Object.values(swagger.paths || {})) {
      for (const [method, operation] of Object.entries(pathItem || {})) {
        if (!['post', 'put'].includes(method.toLowerCase())) continue;

        ensureCandidateSoapActionHeader(operation);

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
  operation.parameters.unshift(soapActionHeaderParameter('CreateWorkOrder'));
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

  const patchedFile = path.join('/tmp', `${apiId}-soap-tryout-swagger.json`);
  fs.writeFileSync(patchedFile, JSON.stringify(swagger, null, 2));

  runCurlJson([
    '-X', 'PUT',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `apiDefinition=@${patchedFile};type=application/json`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/swagger`
  ], log);

  log(`SOAP import: DevPortal Try Out example patched for API ${apiId}`);
}


function executeSoapWsdlImport(entry, artifactsRoot, stateRoot, env, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  if (!soapApimReachable(env)) {
    throw new Error(`APIM is not reachable at ${apimUrl}.`);
  }

  if (!entry.spec || !entry.spec.endsWith('.wsdl')) {
    throw new Error(`SOAP import requires entry.spec to be a .wsdl file. Received: ${entry.spec}`);
  }

  const wsdlPath = path.join(artifactsRoot, entry.spec);
  if (!fs.existsSync(wsdlPath)) {
    throw new Error(`SOAP WSDL not found: ${entry.spec}`);
  }

  const token = getPublisherTokenForSoap(env, log);
  const version = entry.version || '1.0.0';
  const context = entry.context || `/${safeName(entry.name).toLowerCase()}`;
  const endpointUrl = `http://telco-backend:8081${entry.soapBackendPath || '/soap/candidate-field-workorder'}`;

  // Avoid the visual confusion of an older REST-shaped SOAP candidate.
  for (const oldName of [
    entry.name,
    'CandidateFieldWorkOrderSOAPFacade',
    'CandidateFieldWorkOrderSOAPAPI'
  ]) {
    deletePublisherApiForSoapIfExists(env, token, oldName, version, log);
  }

  const additionalProperties = {
    name: entry.name,
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

  log(`Creating TRUE SOAP pass-through API through Publisher REST API.`);
  log(`POST ${apimUrl}/api/am/publisher/v4/apis/import-wsdl`);
  log(`implementationType=SOAP`);
  log(`WSDL: ${wsdlPath}`);
  log(`SOAP backend endpoint: ${endpointUrl}`);

  const imported = runCurlJson([
    '-X', 'POST',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `file=@${wsdlPath};type=text/xml`,
    '-F', `additionalProperties=${JSON.stringify(additionalProperties)}`,
    '-F', 'implementationType=SOAP',
    `${apimUrl}/api/am/publisher/v4/apis/import-wsdl`
  ], log);

  const created = imported.data || {};
  if (!created.id) {
    throw new Error(`SOAP import did not return an API id: ${JSON.stringify(created)}`);
  }

  if (created.type && created.type !== 'SOAP') {
    throw new Error(`Created API type is ${created.type}; expected SOAP. Response: ${JSON.stringify(created)}`);
  }

  log(`SOAP API created as Publisher working copy: ${entry.name}:${version} (${created.id}) type=${created.type || 'SOAP'}`);

  patchSoapTryoutExample(env, token, created.id, log);

  return {
    projectDir: wsdlPath,
    apiId: created.id,
    soap: true
  };
}



function ensurePipelineAsyncApiDefinitionStored(env, token, apiId, asyncapiPath, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  if (!apiId) {
    log('AsyncAPI definition sync: missing API id.');
    return;
  }

  if (!asyncapiPath) {
    log('AsyncAPI definition sync: missing AsyncAPI path.');
    return;
  }

  const before = runCurlJson([
    '-H', `Authorization: Bearer ${token}`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/asyncapi`
  ], log, [200, 404, 500]);

  log(`AsyncAPI definition sync: current GET status ${before.status || 'unknown'}. Uploading definition.`);

  runCurlJson([
    '-X', 'PUT',
    '-H', `Authorization: Bearer ${token}`,
    '-F', `file=@${asyncapiPath}`,
    `${apimUrl}/api/am/publisher/v4/apis/${apiId}/asyncapi`
  ], log, [200, 201, 202]);

  log('AsyncAPI definition sync: uploaded AsyncAPI definition into APIM project storage.');
}


function executeAsyncApiImport(entry, artifactsRoot, stateRoot, env, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  if (!soapApimReachable(env)) {
    throw new Error(`APIM is not reachable at ${apimUrl}.`);
  }

  const asyncapiPath = path.join(artifactsRoot, entry.spec);

  if (!fs.existsSync(asyncapiPath)) {
    throw new Error(`Streaming import requires an AsyncAPI file. Not found: ${entry.spec}`);
  }

  const token = getPublisherTokenForSoap(env, log);
  const version = entry.version || '1.0.0';
  const context = entry.context || `/${safeName(entry.name).toLowerCase()}/v1`;
  const endpointUrl = env.TELCO_BACKEND_URL || 'http://telco-backend:8081';
  const streamingType = entry.type || entry.protocol || 'SSE';

  const created = importStreamingApi({
    apimUrl,
    token,
    name: entry.name,
    version,
    context,
    asyncapiPath,
    endpointUrl,
    type: streamingType,
    governanceLabels: entry.governanceLabels || [],
    deleteExisting: true,
    deploy: false,
    publish: false,
    log
  });

  ensurePipelineAsyncApiDefinitionStored(env, token, created.id, asyncapiPath, log);


  return {
    projectDir: asyncapiPath,
    apiId: created.id,
    streaming: true
  };
} function executeGraphQLImport(entry, artifactsRoot, stateRoot, env, log) {
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';

  if (!soapApimReachable(env)) {
    throw new Error(`APIM is not reachable at ${apimUrl}.`);
  }

  const schemaPath = path.join(artifactsRoot, entry.spec);

  if (!fs.existsSync(schemaPath)) {
    throw new Error(`GraphQL import requires an SDL schema file. Not found: ${entry.spec}`);
  }

  const token = getPublisherTokenForSoap(env, log);
  const version = entry.version || '1.0.0';
  const context = entry.context || `/${safeName(entry.name).toLowerCase()}/v1`;
  const endpointUrl = `${env.TELCO_BACKEND_URL || 'http://telco-backend:8081'}${entry.graphqlBackendPath || '/graphql/partner-insights'}`;

  const created = importGraphQLApi({
    apimUrl,
    token,
    name: entry.name,
    version,
    context,
    schemaPath,
    endpointUrl,
    deleteExisting: true,
    deploy: false,
    publish: false,
    log
  });

  return {
    projectDir: schemaPath,
    apiId: created.id,
    graphql: true
  };
} function executeRealImport(entry, artifactsRoot, stateRoot, env, log) {
  if (
    entry.protocol === 'GRAPHQL' ||
    entry.type === 'GRAPHQL' ||
    /GraphQL/i.test(entry.contractType || '') ||
    /\.graphql$/i.test(entry.spec || '')
  ) {
    return executeGraphQLImport(entry, artifactsRoot, stateRoot, env, log);
  }


  // Hard SOAP/WSDL shortcut: WSDL-based APIs must never go through APICTL/OpenAPI project generation.
  if (
    entry.spec?.endsWith('.wsdl') ||
    entry.protocol === 'SOAP' ||
    entry.type === 'SOAP' ||
    /SOAP\/WSDL/i.test(entry.contractType || '')
  ) {
    return executeSoapWsdlImport(entry, artifactsRoot, stateRoot, env, log);
  }

  if (
    entry.protocol === 'SSE' ||
    entry.type === 'SSE' ||
    entry.protocol === 'ASYNC' ||
    entry.type === 'ASYNC' ||
    /AsyncAPI/i.test(entry.contractType || '') ||
    /\.asyncapi\.ya?ml$/i.test(entry.spec || '')
  ) {
    return executeAsyncApiImport(entry, artifactsRoot, stateRoot, env, log);
  }

  const cli = apictlStatus();
  if (!cli.available) {
    throw new Error(`apictl is not available in the pipeline container. Output: ${cli.output}`);
  }

  const apim = apimStatus(env);
  if (!apim.reachable) {
    throw new Error(`APIM is not reachable at ${env.WSO2_APIM_URL || 'https://wso2-apim:9443'}. Output: ${apim.output}`);
  }

  const insecure = env.APIM_INSECURE_TLS === 'true' ? ['-k'] : [];
  const apimEnv = env.APIM_ENV || 'am47';
  const apimUrl = env.WSO2_APIM_URL || 'https://wso2-apim:9443';
  const username = env.APIM_USERNAME || 'admin';
  const password = env.APIM_PASSWORD || 'admin';

  const workDir = path.join(stateRoot, 'apictl-projects');
  const projectDir = path.join(workDir, `${safeName(entry.name)}-${entry.version || '1.0.0'}`);

  const importSpecRel = entry.importSpec || entry.spec;
  const importSpecPath = path.join(artifactsRoot, importSpecRel);

  if (!fs.existsSync(importSpecPath)) {
    throw new Error(`Import contract not found: ${importSpecRel}`);
  }

  fs.rmSync(projectDir, { recursive: true, force: true });
  fs.mkdirSync(workDir, { recursive: true });

  const openApi = loadYaml(importSpecPath);
  const basePath = openApi['x-wso2-basePath'] || `/${safeName(entry.name).toLowerCase()}/v1`;

  const definitionPath = path.join(workDir, `${safeName(entry.name)}-definition.yaml`);

  writeYaml(definitionPath, {
    type: 'api',
    version: 'v4.7.0',
    data: {
      name: entry.name,
      version: entry.version || '1.0.0',
      context: basePath,
      lifeCycleStatus: 'CREATED',
      type: 'HTTP',
      transport: ['http', 'https'],
      visibility: 'PUBLIC',
      provider: username,
      policies: ['Unlimited'],
      endpointImplementationType: 'ENDPOINT',
      endpointConfig: {
        endpoint_type: 'http',
        production_endpoints: {
          url: 'http://telco-backend:8081'
        },
        sandbox_endpoints: {
          url: 'http://telco-backend:8081'
        }
      }
    }
  });

  run('apictl', ['version'], log);
  runAllowingAlreadyExists('apictl', ['add', 'env', apimEnv, '--apim', apimUrl, '--token', `${apimUrl}/oauth2/token`, ...insecure], log);
  run('apictl', ['login', apimEnv, '-u', username, '-p', password, ...insecure], log);
  run('apictl', ['init', projectDir, '--oas', importSpecPath, '--definition', definitionPath, '--force=true'], log);

  patchApiProject(projectDir, entry, openApi, username);

  if (entry.importSpec) {
    log(`Using governance contract ${entry.spec}; importing APIM working copy from OpenAPI façade ${entry.importSpec}.`);
  }

  if (entry.supplementalSpec) {
    log(`Supplemental contract retained for traceability: ${entry.supplementalSpec}.`);
  }

  run('apictl', ['import', 'api', '--file', projectDir, '--environment', apimEnv, '--dry-run', ...insecure], log);
  run('apictl', ['import', 'api', '--file', projectDir, '--environment', apimEnv, '--update=true', '--skip-deployments', ...insecure], log);

  try {
    const labelToken = getPublisherTokenForSoap(env, log);
    const importedApi = findPublisherApiForSoap(env, labelToken, entry.name, entry.version || '1.0.0', log);

    if (importedApi?.id) {
      attachPipelineGovernanceLabels(env, labelToken, importedApi.id, entry, log);
    } else {
      log(`Governance labels: imported REST API not found in Publisher for ${entry.name}.`);
    }
  } catch (e) {
    log(`Governance labels: failed to attach labels to ${entry.name}. ${e.message}`);
  }

  
  try {
    const labelToken = getPublisherTokenForSoap(env, log);
    attachPipelineGovernanceLabelsByEntry(env, labelToken, entry, log);
  } catch (e) {
    log(`Governance labels: failed to attach labels to ${entry.name}. ${e.message}`);
  }

return { projectDir };
}

function patchApiProject(projectDir, entry, openApi, username) {
  const apiYaml = path.join(projectDir, 'api.yaml');

  if (fs.existsSync(apiYaml)) {
    const doc = loadYaml(apiYaml) || {};

    doc.type = doc.type || 'api';
    doc.version = 'v4.7.0';
    doc.data = doc.data || {};

    doc.data.name = entry.name;
    doc.data.version = entry.version || '1.0.0';
    doc.data.context = openApi['x-wso2-basePath'] || doc.data.context || `/${safeName(entry.name).toLowerCase()}/v1`;
    doc.data.lifeCycleStatus = 'CREATED';
    doc.data.type = 'HTTP';
    doc.data.provider = doc.data.provider || username;
    doc.data.transport = ['http', 'https'];
    doc.data.visibility = 'PUBLIC';
    doc.data.endpointImplementationType = 'ENDPOINT';
    doc.data.policies = doc.data.policies && doc.data.policies.length ? doc.data.policies : ['Unlimited'];
    doc.data.endpointConfig = {
      endpoint_type: 'http',
      production_endpoints: {
        url: 'http://telco-backend:8081'
      },
      sandbox_endpoints: {
        url: 'http://telco-backend:8081'
      }
    };

    writeYaml(apiYaml, doc);
  }

  // Keep the API as a Publisher working copy only.
  // No deployment environments = no deployed revision.
  const deploymentEnv = path.join(projectDir, 'deployment_environments.yaml');
  writeYaml(deploymentEnv, {
    type: 'deployment_environments',
    version: 'v4.7.0',
    data: []
  });
}

function runAllowingAlreadyExists(cmd, args, log) {
  const printable = `${cmd} ${args.join(' ')}`.replace(/-p\s+\S+/, '-p ********');
  log(`$ ${printable}`);

  try {
    const out = execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 180000
    });

    if (out) {
      log(out.trim());
    }
  } catch (e) {
    const stdout = e.stdout?.toString?.().trim() || '';
    const stderr = e.stderr?.toString?.().trim() || '';
    const combined = `${stdout}\n${stderr}`;

    if (stdout) log(stdout);
    if (stderr) log(stderr);

    if (combined.includes('already exists')) {
      log(`Environment already exists. Continuing with existing APICTL environment.`);
      return;
    }

    throw new Error(`${printable} failed`);
  }
}

function run(cmd, args, log) {
  const printable = `${cmd} ${args.join(' ')}`.replace(/-p\s+\S+/, '-p ********');
  log(`$ ${printable}`);

  try {
    const out = execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 180000
    });

    if (out) {
      log(out.trim());
    }
  } catch (e) {
    const stdout = e.stdout?.toString?.().trim();
    const stderr = e.stderr?.toString?.().trim();

    if (stdout) log(stdout);
    if (stderr) log(stderr);

    throw new Error(`${printable} failed`);
  }
}

module.exports = {
  createArtifact,
  commandPlan,
  executeRealImport,
  effectiveMode
};

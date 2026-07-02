const fs = require('fs');
const path = require('path');
const YAML = require('yaml');

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, 'utf8'));
}

function readText(file) {
  return fs.readFileSync(file, 'utf8');
}

function validate(entry, root) {
  const file = path.join(root, entry.spec);
  const protocol = String(entry.protocol || '').toUpperCase();

  if (!fs.existsSync(file)) {
    return violation('CRITICAL', 'artifact-found', 'Artifact file must exist', entry.spec);
  }

  if (protocol === 'REST') return validateOpenApi(entry, file);
  if (protocol === 'ASYNC') return validateAsyncApi(entry, file);
  if (protocol === 'GRAPHQL') return validateGraphQL(entry, file, root);
  if (protocol === 'SOAP') return validateSoap(entry, file, root);

  return violation('ERROR', 'protocol-supported', 'Protocol must be REST, SOAP, ASYNC, or GRAPHQL', entry.protocol);
}

function validateOpenApi(entry, file) {
  const doc = loadYaml(file);
  const findings = [];
  requireValue(findings, doc.openapi, 'openapi-version', 'OpenAPI version is required', '$.openapi');
  requireValue(findings, doc.info && doc.info.title, 'info-title', 'API title is required', '$.info.title');
  requireValue(findings, doc.info && doc.info.version, 'info-version', 'API version is required', '$.info.version');
  requireValue(findings, doc.paths && Object.keys(doc.paths).length, 'paths-defined', 'At least one resource path is required', '$.paths');
  requireValue(findings, doc['x-wso2-basePath'], 'wso2-basepath', 'x-wso2-basePath is required for APIM context alignment', '$.x-wso2-basePath');
  requireValue(findings, doc['x-wso2-throttling-tier'], 'rate-limit-tier', 'x-wso2-throttling-tier is required', '$.x-wso2-throttling-tier');
  requireValue(findings, doc['x-telco-owner'], 'telco-owner', 'Business/API owner is required', '$.x-telco-owner');
  requireValue(findings, doc['x-telco-country-scope'], 'country-scope', 'Country/market scope is required for multinational governance', '$.x-telco-country-scope');
  requireValue(findings, doc['x-telco-data-classification'], 'data-classification', 'Data classification is required', '$.x-telco-data-classification');
  requireValue(findings, doc['x-telco-monetization-model'], 'monetization-model', 'Monetization model is required', '$.x-telco-monetization-model');
  requireValue(findings, doc['x-telco-api-product'], 'api-product', 'API product mapping is required', '$.x-telco-api-product');
  requireValue(findings, doc['x-telco-healthcheck'] && doc['x-telco-healthcheck'].path, 'health-path', 'Health check path is required', '$.x-telco-healthcheck.path');
  requireValue(findings, doc['x-telco-healthcheck'] && doc['x-telco-healthcheck'].method, 'health-method', 'Health check method is required', '$.x-telco-healthcheck.method');
  requireValue(findings, doc.components && doc.components.securitySchemes, 'security-scheme', 'Security scheme is required', '$.components.securitySchemes');
  requireValue(findings, doc.security, 'security-applied', 'API-level security declaration is required', '$.security');

  for (const [pathKey, ops] of Object.entries(doc.paths || {})) {
    for (const [method, op] of Object.entries(ops || {})) {
      if (!['get','post','put','patch','delete','head','options','trace'].includes(method)) continue;
      requireValue(findings, op.operationId, 'operation-id', `operationId is required for ${method.toUpperCase()} ${pathKey}`, `$.paths.${pathKey}.${method}.operationId`);
      requireValue(findings, op.responses && Object.keys(op.responses).length, 'responses', `Responses are required for ${method.toUpperCase()} ${pathKey}`, `$.paths.${pathKey}.${method}.responses`);
      requireValue(findings, op.tags && op.tags.length, 'operation-tags', `Tags are required for ${method.toUpperCase()} ${pathKey}`, `$.paths.${pathKey}.${method}.tags`);
    }
  }
  return summarize(entry, findings);
}

function validateAsyncApi(entry, file) {
  const doc = loadYaml(file);
  const findings = [];
  requireValue(findings, doc.asyncapi, 'asyncapi-version', 'AsyncAPI version is required', '$.asyncapi');
  requireValue(findings, doc.info && doc.info.title, 'info-title', 'Streaming API title is required', '$.info.title');
  requireValue(findings, doc.info && doc.info.version, 'info-version', 'Streaming API version is required', '$.info.version');
  requireValue(findings, doc.channels && Object.keys(doc.channels).length, 'channels-defined', 'At least one channel/topic is required', '$.channels');
  requireValue(findings, doc.servers && Object.keys(doc.servers).length, 'servers-defined', 'At least one streaming server is required', '$.servers');
  requireValue(findings, doc['x-telco-owner'], 'telco-owner', 'Business/API owner is required', '$.x-telco-owner');
  requireValue(findings, doc['x-telco-country-scope'], 'country-scope', 'Country/market scope is required', '$.x-telco-country-scope');
  requireValue(findings, doc['x-telco-event-classification'], 'event-classification', 'Event classification is required', '$.x-telco-event-classification');
  requireValue(findings, doc['x-telco-event-retention'], 'event-retention', 'Event retention policy is required', '$.x-telco-event-retention');
  requireValue(findings, doc['x-telco-monetization-model'], 'monetization-model', 'Streaming monetization model is required', '$.x-telco-monetization-model');
  return summarize(entry, findings);
}

function validateGraphQL(entry, file, root) {
  const schema = readText(file);
  const findings = [];

  requireValue(findings, /schema\s*\{/.test(schema) || /type\s+Query\s*\{/.test(schema), 'graphql-schema', 'GraphQL schema or Query root is required', '$.schema');
  requireValue(findings, /type\s+Query\s*\{/.test(schema), 'graphql-query-root', 'GraphQL Query root type is required', 'type Query');
  requireValue(findings, /partnerPortfolio|partnerInsight|marketplaceRecommendations|subscriberOpportunity/.test(schema), 'graphql-business-operations', 'At least one telco partner insight query is required', 'type Query');

  if (entry.metadata) {
    const mdPath = path.join(root, entry.metadata);
    if (!fs.existsSync(mdPath)) {
      findings.push(makeFinding('ERROR', 'graphql-metadata', 'GraphQL governance sidecar metadata is missing', entry.metadata));
    } else {
      const md = loadYaml(mdPath);
      requireValue(findings, md.owner, 'telco-owner', 'Business/API owner is required', '$.owner');
      requireValue(findings, md.countryScope, 'country-scope', 'Country/market scope is required', '$.countryScope');
      requireValue(findings, md.dataClassification, 'data-classification', 'Data classification is required', '$.dataClassification');
      requireValue(findings, md.monetizationModel, 'monetization-model', 'Monetization model is required', '$.monetizationModel');
      requireValue(findings, md.apiProduct, 'api-product', 'API product mapping is required', '$.apiProduct');
      requireValue(findings, md.healthcheck && md.healthcheck.path, 'health-path', 'GraphQL health check path is required', '$.healthcheck.path');
      requireValue(findings, md.healthcheck && md.healthcheck.method, 'health-method', 'GraphQL health check method is required', '$.healthcheck.method');
      requireValue(findings, md.healthcheck && md.healthcheck.query, 'health-query', 'GraphQL health check query is required', '$.healthcheck.query');
      requireValue(findings, md.security, 'security-scheme', 'Security model is required', '$.security');
      requireValue(findings, md.complexity && md.complexity.maxDepth, 'complexity-depth', 'GraphQL max query depth policy is required', '$.complexity.maxDepth');
      requireValue(findings, md.complexity && md.complexity.maxComplexity, 'complexity-cost', 'GraphQL query complexity policy is required', '$.complexity.maxComplexity');
    }
  } else {
    findings.push(makeFinding('ERROR', 'graphql-metadata', 'GraphQL governance sidecar metadata is required', '$.metadata'));
  }

  return summarize(entry, findings);
} function validateSoap(entry, file, root) {
  const wsdl = readText(file);
  const findings = [];
  requireValue(findings, /definitions|wsdl:definitions/.test(wsdl), 'wsdl-definitions', 'WSDL definitions are required', 'wsdl:definitions');
  requireValue(findings, /soap:address/.test(wsdl), 'soap-address', 'SOAP endpoint address is required', 'soap:address');
  requireValue(findings, /operation name=/.test(wsdl), 'soap-operations', 'At least one SOAP operation is required', 'wsdl:operation');
  if (entry.metadata) {
    const mdPath = path.join(root, entry.metadata);
    if (!fs.existsSync(mdPath)) findings.push(makeFinding('ERROR', 'soap-metadata', 'SOAP governance sidecar metadata is missing', entry.metadata));
    else {
      const md = loadYaml(mdPath);
      requireValue(findings, md.owner, 'telco-owner', 'Business/API owner is required', '$.owner');
      requireValue(findings, md.countryScope, 'country-scope', 'Country/market scope is required', '$.countryScope');
      requireValue(findings, md.dataClassification, 'data-classification', 'Data classification is required', '$.dataClassification');
      requireValue(findings, md.monetizationModel, 'monetization-model', 'Monetization model is required', '$.monetizationModel');
      requireValue(findings, md.healthcheck && md.healthcheck.path, 'health-path', 'Health check path is required', '$.healthcheck.path');
      requireValue(findings, md.security, 'security-scheme', 'Security model is required', '$.security');
    }
  } else {
    findings.push(makeFinding('ERROR', 'soap-metadata', 'SOAP governance sidecar metadata is required', '$.metadata'));
  }
  return summarize(entry, findings);
}

function requireValue(findings, value, ruleName, message, path) {
  if (value === undefined || value === null || value === '' || value === 0 || (Array.isArray(value) && value.length === 0)) {
    findings.push(makeFinding('ERROR', ruleName, message, path));
  }
}

function makeFinding(severity, ruleName, message, path) {
  return { severity, ruleName, message, violatedPath: path };
}

function violation(severity, ruleName, message, path) {
  return { approved: false, findings: [makeFinding(severity, ruleName, message, path)], score: 0 };
}

function summarize(entry, findings) {
  const errors = findings.filter(f => ['ERROR', 'CRITICAL'].includes(f.severity)).length;
  const score = Math.max(0, 100 - errors * 12 - findings.filter(f => f.severity === 'WARN').length * 4);
  return { approved: errors === 0, findings, score, apiId: entry.id, name: entry.name };
}

module.exports = { validate };

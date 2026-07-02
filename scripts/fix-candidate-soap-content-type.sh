#!/usr/bin/env sh
set -eu

API_NAME="${1:-CandidateFieldWorkOrderSOAPAPI}"
API_VERSION="${2:-0.9.0}"
APIM_URL="${APIM_URL:-https://wso2-apim:9443}"
USER="${APIM_USERNAME:-admin}"
PASS="${APIM_PASSWORD:-admin}"

RAW="/tmp/${API_NAME}-swagger-current.json"
PATCHED="/tmp/${API_NAME}-swagger-content-type-fixed.json"
RESPONSE_FILE="/tmp/${API_NAME}-content-type-update-response.txt"

SOAP_SAMPLE='<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:fw="http://example.com/telco/field-workorder">
  <soapenv:Header/>
  <soapenv:Body>
    <fw:CreateWorkOrderRequest>
      <fw:customerId>CUST-10001</fw:customerId>
      <fw:siteId>BR-SP-EDGE-03</fw:siteId>
      <fw:priority>HIGH</fw:priority>
      <fw:description>Field technician required for site inspection.</fw:description>
    </fw:CreateWorkOrderRequest>
  </soapenv:Body>
</soapenv:Envelope>'

echo "Registering temporary Publisher client..."

DCR="$(curl -k -sS -u "$USER:$PASS" \
  -H "Content-Type: application/json" \
  -d "{\"callbackUrl\":\"http://localhost:8090/callback\",\"clientName\":\"candidate-soap-content-type-fixer-$(date +%s)\",\"owner\":\"$USER\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
  "$APIM_URL/client-registration/v0.17/register")"

CID="$(node -e "console.log(JSON.parse(process.argv[1]).clientId)" "$DCR")"
SEC="$(node -e "console.log(JSON.parse(process.argv[1]).clientSecret)" "$DCR")"

TOKEN="$(curl -k -sS -u "$CID:$SEC" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode grant_type=password \
  --data-urlencode username="$USER" \
  --data-urlencode password="$PASS" \
  --data-urlencode "scope=apim:api_view apim:api_update apim:api_manage apim:api_publish" \
  "$APIM_URL/oauth2/token" \
  | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>console.log(JSON.parse(s).access_token))")"

API_ID="$(curl -k -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$APIM_URL/api/am/publisher/v4/apis?query=name:$API_NAME&limit=100" \
  | node -e "
    let s='';
    process.stdin.on('data',d=>s+=d);
    process.stdin.on('end',()=> {
      const data = JSON.parse(s);
      const list = data.list || data.data || [];
      const api = list.find(a => a.name === process.argv[1] && (!a.version || a.version === process.argv[2]));
      if (!api) {
        console.error('API not found');
        process.exit(2);
      }
      console.log(api.id);
    });
  " "$API_NAME" "$API_VERSION")"

echo "API ID: $API_ID"

curl -k -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$APIM_URL/api/am/publisher/v4/apis/$API_ID/swagger" \
  > "$RAW"

SOAP_SAMPLE="$SOAP_SAMPLE" node - "$RAW" "$PATCHED" <<'NODE'
const fs = require('fs');

const input = process.argv[2];
const output = process.argv[3];
const sample = process.env.SOAP_SAMPLE;

const api = JSON.parse(fs.readFileSync(input, 'utf8'));

function removeJsonContentTypes(value) {
  if (!Array.isArray(value)) return ['text/xml', 'application/xml'];
  const cleaned = value.filter(v => !String(v).toLowerCase().includes('json'));
  return cleaned.length ? cleaned : ['text/xml', 'application/xml'];
}

function patchSwagger2Operation(operation) {
  operation.consumes = ['text/xml', 'application/xml'];
  operation.produces = ['text/xml', 'application/xml'];

  operation.parameters = Array.isArray(operation.parameters) ? operation.parameters : [];

  // Remove invalid/undesired content-type headers if they were generated before.
  operation.parameters = operation.parameters.filter(p => {
    const name = String(p.name || '').toLowerCase();
    return !(p.in === 'header' && name === 'content-type');
  });

  let soapAction = operation.parameters.find(p =>
    p.in === 'header' && String(p.name || '').toLowerCase() === 'soapaction'
  );

  if (!soapAction) {
    soapAction = {
      name: 'SOAPAction',
      in: 'header',
      required: false,
      type: 'string',
      default: 'CreateWorkOrder',
      description: 'SOAP 1.1 action header.'
    };
    operation.parameters.unshift(soapAction);
  } else {
    soapAction.name = 'SOAPAction';
    soapAction.in = 'header';
    soapAction.required = false;
    soapAction.type = 'string';
    soapAction.default = 'CreateWorkOrder';
    soapAction.description = 'SOAP 1.1 action header.';
    delete soapAction.schema;
  }

  let body = operation.parameters.find(p => p.in === 'body');

  if (!body) {
    body = {
      name: 'SOAP Request',
      in: 'body',
      required: true,
      description: 'SOAP request envelope. Copy the default SOAP envelope shown above into this field, keep parameter content type as text/xml, and execute with SOAPAction=CreateWorkOrder.'
    };
    operation.parameters.push(body);
  }

  body.name = 'SOAP Request';
  body.in = 'body';
  body.required = true;
  body.description = 'SOAP request envelope. Copy the default SOAP envelope shown above into this field, keep parameter content type as text/xml, and execute with SOAPAction=CreateWorkOrder. Copy the default SOAP envelope shown above into this field, keep parameter content type as text/xml, and execute with SOAPAction=CreateWorkOrder.';

  // Keep this as string so the textbox can contain raw XML.
  body.schema = {
    type: 'string',
    default: sample,
    example: sample
  };

  operation['x-examples'] = {
    'text/xml': sample,
    'application/xml': sample
  };

  delete operation.examples;
}

if (api.swagger) {
  api.consumes = ['text/xml', 'application/xml'];
  api.produces = ['text/xml', 'application/xml'];

  for (const pathItem of Object.values(api.paths || {})) {
    for (const [method, operation] of Object.entries(pathItem || {})) {
      if (!['post', 'put'].includes(method.toLowerCase())) continue;
      patchSwagger2Operation(operation);
    }
  }
} else if (api.openapi) {
  for (const pathItem of Object.values(api.paths || {})) {
    for (const [method, operation] of Object.entries(pathItem || {})) {
      if (!['post', 'put'].includes(method.toLowerCase())) continue;

      operation.parameters = Array.isArray(operation.parameters) ? operation.parameters : [];
      operation.parameters = operation.parameters.filter(p => {
        const name = String(p.name || '').toLowerCase();
        return !(p.in === 'header' && name === 'content-type');
      });

      if (!operation.parameters.some(p => p.in === 'header' && String(p.name || '').toLowerCase() === 'soapaction')) {
        operation.parameters.unshift({
          name: 'SOAPAction',
          in: 'header',
          required: false,
          schema: {
            type: 'string',
            default: 'CreateWorkOrder'
          },
          example: 'CreateWorkOrder',
          description: 'SOAP 1.1 action header.'
        });
      }

      operation.requestBody = {
        required: true,
        description: 'SOAP request envelope. Copy the default SOAP envelope shown above into this field, keep parameter content type as text/xml, and execute with SOAPAction=CreateWorkOrder.',
        content: {
          'text/xml': {
            schema: {
              type: 'string',
              default: sample,
              example: sample
            },
            example: sample
          },
          'application/xml': {
            schema: {
              type: 'string',
              default: sample,
              example: sample
            },
            example: sample
          }
        }
      };
    }
  }
} else {
  throw new Error('Unknown API definition format');
}

// Clean any global JSON content types that may still exist.
if (api.consumes) api.consumes = removeJsonContentTypes(api.consumes);
if (api.produces) api.produces = removeJsonContentTypes(api.produces);

fs.writeFileSync(output, JSON.stringify(api, null, 2));
console.log(`Wrote ${output}`);
NODE

echo "Checking for remaining application/json..."
if grep -q "application/json" "$PATCHED"; then
  echo "ERROR: application/json is still present in patched definition."
  grep -n "application/json" "$PATCHED" -C 3
  exit 1
fi

echo "Updating API definition..."

HTTP_CODE="$(curl -k -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -F "apiDefinition=@${PATCHED};type=application/json" \
  "$APIM_URL/api/am/publisher/v4/apis/$API_ID/swagger")"

echo "HTTP status: $HTTP_CODE"
cat "$RESPONSE_FILE" || true
echo

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "Definition update failed."
  exit 1
fi

echo "SOAP content type fixed for $API_NAME:$API_VERSION"

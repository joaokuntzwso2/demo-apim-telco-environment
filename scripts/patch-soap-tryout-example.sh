#!/usr/bin/env sh
set -eu

API_NAME="${1:-CandidateFieldWorkOrderSOAPAPI}"
API_VERSION="${2:-0.9.0}"
APIM_URL="${APIM_URL:-https://wso2-apim:9443}"
USER="${APIM_USERNAME:-admin}"
PASS="${APIM_PASSWORD:-admin}"

RAW="/tmp/${API_NAME}-swagger.json"
PATCHED="/tmp/${API_NAME}-swagger-patched.json"
SOAP_SAMPLE_FILE="/tmp/${API_NAME}-soap-sample.xml"
RESPONSE_FILE="/tmp/${API_NAME}-swagger-update-response.txt"

cat > "$SOAP_SAMPLE_FILE" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
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
</soapenv:Envelope>
XML

echo "Registering temporary Publisher client..."

DCR="$(curl -k -sS -u "$USER:$PASS" \
  -H "Content-Type: application/json" \
  -d "{\"callbackUrl\":\"http://localhost:8090/callback\",\"clientName\":\"soap-tryout-patcher-$(date +%s)\",\"owner\":\"$USER\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
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

echo "Looking up API: $API_NAME:$API_VERSION"

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

echo "Downloading generated Swagger/OpenAPI definition..."

curl -k -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$APIM_URL/api/am/publisher/v4/apis/$API_ID/swagger" \
  > "$RAW"

echo "Patching SOAP example into definition..."

node - "$RAW" "$PATCHED" "$SOAP_SAMPLE_FILE" <<'NODE'
const fs = require('fs');

const input = process.argv[2];
const output = process.argv[3];
const sampleFile = process.argv[4];

const sample = fs.readFileSync(sampleFile, 'utf8');
const api = JSON.parse(fs.readFileSync(input, 'utf8'));

if (api.swagger) {
  api.consumes = ['text/xml', 'application/xml'];
  api.produces = ['text/xml', 'application/xml'];

  for (const pathItem of Object.values(api.paths || {})) {
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
      body.schema = {
        type: 'string',
        example: sample
      };

      operation['x-examples'] = {
        'text/xml': sample,
        'application/xml': sample
      };
    }
  }
} else if (api.openapi) {
  for (const pathItem of Object.values(api.paths || {})) {
    for (const [method, operation] of Object.entries(pathItem || {})) {
      if (!['post', 'put'].includes(method.toLowerCase())) continue;

      operation.summary = operation.summary || 'Invoke SOAP operation';
      operation.description = 'Paste a SOAP envelope and invoke the SOAP pass-through API.';
      operation.requestBody = {
        required: true,
        content: {
          'text/xml': {
            schema: { type: 'string' },
            example: sample
          },
          'application/xml': {
            schema: { type: 'string' },
            example: sample
          }
        }
      };
    }
  }
} else {
  throw new Error('Unknown API definition format');
}

fs.writeFileSync(output, JSON.stringify(api, null, 2));
console.log(`Wrote patched definition to ${output}`);
NODE

echo "Generated files:"
ls -l "$RAW" "$PATCHED" "$SOAP_SAMPLE_FILE"

echo "Updating generated API definition with SOAP example..."

HTTP_CODE="$(curl -k -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -F "apiDefinition=@${PATCHED};type=application/json" \
  "$APIM_URL/api/am/publisher/v4/apis/$API_ID/swagger")"

echo "HTTP status: $HTTP_CODE"
echo "Response:"
cat "$RESPONSE_FILE" || true
echo

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "Swagger update failed."
  exit 1
fi

echo "Patched SOAP Try Out example for $API_NAME:$API_VERSION"

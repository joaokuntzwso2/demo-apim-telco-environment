#!/usr/bin/env bash
set -euo pipefail
BASE=${BASE:-http://localhost:8081}

echo "== Health =="
curl -s "$BASE/health" | jq .

echo "== Customer profile =="
curl -s "$BASE/api/v1/customers/%2B525512340001/profile" | jq .

echo "== Network slices =="
curl -s "$BASE/api/v1/network/slices" | jq .

echo "== Reserve slice =="
curl -s -X POST "$BASE/api/v1/network/slices/reservations" \
  -H 'content-type: application/json' \
  -d '{"sliceId":"urllc-qod-gold","country":"BR","partnerId":"ride-hailing","durationMinutes":120,"maxLatencyMs":12}' | jq .

echo "== Partner settlement =="
curl -s "$BASE/api/v1/partners/banking-superapp/settlement" | jq .

echo "== SOAP billing adjustment =="
curl -s -X POST "$BASE/soap/billing-adjustment" \
  -H 'content-type: text/xml' \
  -d '<?xml version="1.0"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:bil="http://demo.telco.wso2.com/billing"><soapenv:Header/><soapenv:Body><bil:CreateBillingAdjustmentRequest><msisdn>+525512340001</msisdn><amount>12.40</amount><currency>USD</currency><reasonCode>ROAMING_CREDIT</reasonCode><requestor>care-agent-778</requestor></bil:CreateBillingAdjustmentRequest></soapenv:Body></soapenv:Envelope>'

echo

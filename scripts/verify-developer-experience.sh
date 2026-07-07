#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-developer-experience-verify.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[verify-developer-experience] ERROR: missing command: $command" >&2
    exit 1
  }
done

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"telco-dx-verifier-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(jq -r '.clientId // empty' <<<"$dcr_response")"
client_secret="$(jq -r '.clientSecret // empty' <<<"$dcr_response")"

if [[ -z "$client_id" || -z "$client_secret" ]]; then
  echo "[verify-developer-experience] ERROR: DCR failed." >&2
  jq . <<<"$dcr_response" >&2 || printf '%s\n' "$dcr_response" >&2
  exit 1
fi

publisher_token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode 'scope=apim:api_view apim:api_manage apim:api_publish apim:api_metadata_view apim:document_create apim:document_manage apim:document_update apim:document_delete' \
    "${APIM_URL}/oauth2/token"
)"
publisher_token="$(jq -r '.access_token // empty' <<<"$publisher_token_response")"

if [[ -z "$publisher_token" ]]; then
  echo "[verify-developer-experience] ERROR: Publisher token request failed." >&2
  jq . <<<"$publisher_token_response" >&2 || printf '%s\n' "$publisher_token_response" >&2
  exit 1
fi

api_names=(
  OpenGatewayNumberVerificationAPI
  OpenGatewaySimSwapRiskAPI
  OpenGatewayDeviceLocationVerificationAPI
  TelcoBusinessCatalogAPI
  Customer360API
  NumberLifecycleAPI
  NetworkSliceAPI
  PartnerChargingAPI
  BillingAdjustmentSOAP
  BillingAdjustmentModernizationAPI
  SecureTransactionRiskAssessmentAPI
  NetworkEventsStreamAPI
)

api_doc_names=(
  "01 - Business Overview"
  "02 - Contract and CAMARA Alignment"
  "03 - Authentication and First Call"
  "04 - Consent and Privacy Requirements"
  "05 - Error Catalogue"
  "06 - Rate Limits and Commercial Plan"
  "07 - SLA Support and Resilience"
  "08 - Code Samples Postman and SDKs"
  "09 - Sandbox Test Data"
)

product_doc_names=(
  "01 - Product Overview and API Map"
  "02 - Product Onboarding and First Call"
  "03 - Consent and Compliance Matrix"
  "04 - Commercial Plans Rate Limits and SLA"
  "05 - Sandbox Postman and SDK Toolkit"
)

publisher_apis="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

failures=0

for api_name in "${api_names[@]}"; do
  api_id="$(
    jq -r --arg name "$api_name" \
      'first(.list[]? | select(.name == $name and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
      <<<"$publisher_apis"
  )"

  if [[ -z "$api_id" ]]; then
    echo "[verify-developer-experience] MISSING API: ${api_name}:1.0.0" >&2
    failures=$((failures + 1))
    continue
  fi

  api_detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}"
  )"

  case "$api_name" in
    OpenGatewayNumberVerificationAPI|OpenGatewaySimSwapRiskAPI|OpenGatewayDeviceLocationVerificationAPI|SecureTransactionRiskAssessmentAPI)
      required_plans="TelcoFreeTrial TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium Unlimited"
      ;;
    TelcoBusinessCatalogAPI|Customer360API|NumberLifecycleAPI)
      required_plans="TelcoFreeTrial TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    NetworkSliceAPI|PartnerChargingAPI)
      required_plans="TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    BillingAdjustmentSOAP|BillingAdjustmentModernizationAPI)
      required_plans="TelcoFreeTrial TelcoPartnerStandard Unlimited"
      ;;
    NetworkEventsStreamAPI)
      required_plans="TelcoFreeTrial TelcoEventStreamPremium Unlimited"
      ;;
    *)
      required_plans="Unlimited"
      ;;
  esac

  for required_plan in $required_plans; do
    if ! jq -e --arg plan "$required_plan"       '((.policies // []) | index($plan)) != null'       <<<"$api_detail" >/dev/null; then
      echo "[verify-developer-experience] MISSING API PLAN: ${api_name} -> ${required_plan}" >&2
      failures=$((failures + 1))
    fi
  done

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/documents?limit=100"
  )"

  for required_doc in "${api_doc_names[@]}"; do
    if ! jq -e --arg name "$required_doc" \
      'any(.list[]?; .name == $name)' <<<"$docs" >/dev/null; then
      echo "[verify-developer-experience] MISSING API DOC: ${api_name} -> ${required_doc}" >&2
      failures=$((failures + 1))
    fi
  done

  echo "[verify-developer-experience] API OK: ${api_name}"
done

publisher_products="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000"
)"

product_ids="$(
  jq -r '.list[]? | [.id, .name] | @tsv' <<<"$publisher_products"
)"

product_count=0
while IFS=$'\t' read -r product_id product_name; do
  [[ -n "$product_id" ]] || continue

  case "$product_name" in
    OpenGatewayFraudDefenseProduct|DigitalCustomerBSSExperienceProduct|FiveGNetworkMonetizationProduct)
      ;;
    *)
      continue
      ;;
  esac

  product_count=$((product_count + 1))
  detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/api-products/${product_id}"
  )"

  state="$(jq -r '(.state // .lifeCycleStatus // .status // "") | ascii_upcase' <<<"$detail")"
  if [[ "$state" != "PUBLISHED" ]]; then
    echo "[verify-developer-experience] PRODUCT NOT PUBLISHED: ${product_name} (${state:-unknown})" >&2
    failures=$((failures + 1))
  fi

  case "$product_name" in
    OpenGatewayFraudDefenseProduct)
      required_product_plans="TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium Unlimited"
      ;;
    DigitalCustomerBSSExperienceProduct)
      required_product_plans="TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    FiveGNetworkMonetizationProduct)
      required_product_plans="TelcoPartnerPremium TelcoEventStreamPremium Unlimited"
      ;;
  esac

  for required_plan in $required_product_plans; do
    if ! jq -e --arg plan "$required_plan"       '((.policies // []) | index($plan)) != null'       <<<"$detail" >/dev/null; then
      echo "[verify-developer-experience] MISSING PRODUCT PLAN: ${product_name} -> ${required_plan}" >&2
      failures=$((failures + 1))
    fi
  done

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/api-products/${product_id}/documents?limit=100"
  )"

  for required_doc in "${product_doc_names[@]}"; do
    if ! jq -e --arg name "$required_doc" \
      'any(.list[]?; .name == $name)' <<<"$docs" >/dev/null; then
      echo "[verify-developer-experience] MISSING PRODUCT DOC: ${product_name} -> ${required_doc}" >&2
      failures=$((failures + 1))
    fi
  done

  echo "[verify-developer-experience] API PRODUCT OK: ${product_name}"
done <<<"$product_ids"

if (( product_count != 3 )); then
  echo "[verify-developer-experience] Expected 3 native API Products, found ${product_count}." >&2
  failures=$((failures + 1))
fi

catalog_token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode 'scope=service_catalog:service_view service_catalog:service_write' \
    "${APIM_URL}/oauth2/token"
)"
catalog_token="$(jq -r '.access_token // empty' <<<"$catalog_token_response")"

if [[ -z "$catalog_token" ]]; then
  echo "[verify-developer-experience] ERROR: Service Catalog token request failed." >&2
  failures=$((failures + 1))
else
  catalog="$(
    curl -ksS \
      -H "Authorization: Bearer ${catalog_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/service-catalog/v1/services?limit=1000"
  )"

  catalog_services=(
    SecureTransactionRiskAssessmentAPI
    CrmRiskAdapterAPI
    SimSwapRiskAdapterAPI
    DeviceLocationRiskAdapterAPI
    OssRiskAdapterAPI
    BillingAdjustmentModernizationAPI
    LegacyBillingAdjustmentSOAPService
  )

  for service_name in "${catalog_services[@]}"; do
    if ! jq -e --arg name "$service_name" \
      'any(.list[]?; .name == $name and .version == "1.0.0")' \
      <<<"$catalog" >/dev/null; then
      echo "[verify-developer-experience] MISSING SERVICE CATALOG ENTRY: ${service_name}:1.0.0" >&2
      failures=$((failures + 1))
    else
      echo "[verify-developer-experience] SERVICE CATALOG OK: ${service_name}"
    fi
  done
fi

if (( failures > 0 )); then
  echo "[verify-developer-experience] FAILED with ${failures} issue(s)." >&2
  exit 1
fi

echo "[verify-developer-experience] PASS: documentation, products, plans and Service Catalog entries are complete."

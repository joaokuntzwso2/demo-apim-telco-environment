#!/usr/bin/env bash
set -Eeuo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

API_NAME="SubscriberAuthorizationControlAPI"
API_VERSION="1.0.0"
API_CONTEXT="/subscriber-authorization/v1"

fail() {
  printf '[oauth-deployment-check][FAIL] %s\n' "$*" >&2
  exit 1
}

work_dir="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/oauth-deployment-check.XXXXXX"
)"

trap 'rm -rf "$work_dir"' EXIT

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"oauth-deployment-check-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r '.clientId // empty' \
    <<<"$dcr_response"
)"

client_secret="$(
  jq -r '.clientSecret // empty' \
    <<<"$dcr_response"
)"

[[ -n "$client_id" && -n "$client_secret" ]] || {
  printf '%s\n' "$dcr_response" >&2
  fail "Dynamic client registration failed."
}

token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish' \
    "${APIM_URL}/oauth2/token"
)"

publisher_token="$(
  jq -r '.access_token // empty' \
    <<<"$token_response"
)"

[[ -n "$publisher_token" ]] || {
  printf '%s\n' "$token_response" >&2
  fail "Publisher token acquisition failed."
}

api_list="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

api_id="$(
  jq -r \
    --arg name "$API_NAME" \
    --arg version "$API_VERSION" '
      first(
        (.list // .data // [])[]?
        | select(
            .name == $name and
            (.version // "") == $version
          )
        | .id
      ) // empty
    ' \
    <<<"$api_list"
)"

[[ -n "$api_id" ]] ||
  fail "${API_NAME}:${API_VERSION} was not found."

deployments="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
)"

revisions="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions?limit=100"
)"

has_successful_deployment() {
  jq -e '
    def top_level_items:
      if type == "array" then .
      elif type == "object" then
        (
          .list //
          .data //
          .deployments //
          .deploymentInfo //
          []
        )
      else []
      end;

    def revision_deployments:
      [
        (
          .list //
          .data //
          (if type == "array" then . else [] end)
        )[]?
        | (.deploymentInfo // [])[]?
      ];

    def successful($item):
      (
        ($item.status // "") == "APPROVED"
      ) and (
        (($item.deployedGatewayCount // 0) > 0) or
        (($item.successDeployedTime // null) != null)
      );

    any(top_level_items[]?; successful(.)) or
    any(revision_deployments[]?; successful(.))
  ' >/dev/null 2>&1
}

if has_successful_deployment <<<"$deployments" ||
   has_successful_deployment <<<"$revisions"
then
  printf '[oauth-deployment-check] %s has a successful Gateway deployment.\n' \
    "$API_NAME"

  exit 0
fi

# A Gateway OAuth rejection proves that the API route exists and is secured.
gateway_status="$(
  curl -ksS \
    -o "$work_dir/gateway-response.json" \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "https://127.0.0.1:8243${API_CONTEXT}/number-verifications" ||
    true
)"

case "$gateway_status" in
  401|403)
    printf '[oauth-deployment-check] %s route is active on the Gateway.\n' \
      "$API_NAME"

    exit 0
    ;;
esac

echo "[oauth-deployment-check] Publisher deployments:" >&2
jq . <<<"$deployments" >&2 ||
  printf '%s\n' "$deployments" >&2

echo "[oauth-deployment-check] Publisher revisions:" >&2
jq . <<<"$revisions" >&2 ||
  printf '%s\n' "$revisions" >&2

echo "[oauth-deployment-check] Gateway status: $gateway_status" >&2

fail "$API_NAME does not have a successful Gateway deployment."

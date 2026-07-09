#!/usr/bin/env bash
set -Eeuo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

API_NAME="SubscriberAuthorizationControlAPI"
API_VERSION="1.0.0"
API_CONTEXT="/subscriber-authorization/v1"

WORK_DIR="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/oauth-api-deployment.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

log() {
  printf '[oauth-api-deployment] %s\n' "$*"
}

fail() {
  printf '[oauth-api-deployment][FAIL] %s\n' \
    "$*" >&2
  exit 1
}

dcr="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"oauth-api-deployment-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r '.clientId // empty' \
    <<<"$dcr"
)"

client_secret="$(
  jq -r '.clientSecret // empty' \
    <<<"$dcr"
)"

[[ -n "$client_id" && -n "$client_secret" ]] || {
  printf '%s\n' "$dcr" >&2
  fail "Dynamic client registration failed."
}

token_json="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish' \
    "${APIM_URL}/oauth2/token"
)"

token="$(
  jq -r '.access_token // empty' \
    <<<"$token_json"
)"

[[ -n "$token" ]] || {
  printf '%s\n' "$token_json" >&2
  fail "Publisher token acquisition failed."
}

apis="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
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
    <<<"$apis"
)"

[[ -n "$api_id" ]] ||
  fail \
    "${API_NAME}:${API_VERSION} was not found."

deployment_exists() {
  jq -e '
    def deployment_items:
      if type == "array" then .
      elif type == "object" then
        (
          .list //
          .data //
          .deployments //
          .deploymentInfo //
          .deploymentEnvironments //
          []
        )
      else []
      end;

    ((.count // 0) > 0) or
    ((deployment_items | length) > 0)
  ' >/dev/null 2>&1
}

deployments="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
)"

if deployment_exists <<<"$deployments"; then
  log \
    "${API_NAME} already has a deployed revision."

  exit 0
fi

log \
  "${API_NAME} has no control-plane deployment; creating a fresh revision."

revisions="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions?limit=100"
)"

revision_count="$(
  jq -r '
    (
      .list //
      .data //
      (if type == "array" then . else [] end)
    )
    | length
  ' \
    <<<"$revisions"
)"

if [[ "$revision_count" =~ ^[0-9]+$ ]] &&
   (( revision_count >= 5 ))
then
  oldest_revision="$(
    jq -r '
      (
        .list //
        .data //
        (if type == "array" then . else [] end)
      )
      | sort_by(
          .createdTime //
          .revisionNumber //
          .id
        )
      | first
      | (.id // .revisionId // empty)
    ' \
      <<<"$revisions"
  )"

  [[ -n "$oldest_revision" ]] ||
    fail \
      "Five revisions exist, but the oldest ID could not be resolved."

  log \
    "Removing oldest undeployed revision ${oldest_revision}."

  delete_status="$(
    curl -ksS \
      -o "$WORK_DIR/delete.json" \
      -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer ${token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions/${oldest_revision}"
  )"

  case "$delete_status" in
    200|202|204)
      ;;
    *)
      cat "$WORK_DIR/delete.json" >&2

      fail \
        "Could not delete the oldest revision; HTTP ${delete_status}."
      ;;
  esac
fi

create_status="$(
  curl -ksS \
    -o "$WORK_DIR/revision.json" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{
      "description":
        "OAuth persona consent purpose country and partner-control deployment"
    }' \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions"
)"

case "$create_status" in
  200|201|202)
    ;;
  *)
    cat "$WORK_DIR/revision.json" >&2

    fail \
      "Revision creation failed; HTTP ${create_status}."
    ;;
esac

revision_id="$(
  jq -r \
    '.id // .revisionId // empty' \
    "$WORK_DIR/revision.json"
)"

[[ -n "$revision_id" ]] || {
  cat "$WORK_DIR/revision.json" >&2

  fail \
    "Revision creation did not return an ID."
}

deploy_status="$(
  curl -ksS \
    -o "$WORK_DIR/deploy.json" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '[
      {
        "name":"Default",
        "vhost":"localhost",
        "displayOnDevportal":true
      }
    ]' \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deploy-revision?revisionId=${revision_id}"
)"

case "$deploy_status" in
  200|201|202)
    ;;
  *)
    cat "$WORK_DIR/deploy.json" >&2

    fail \
      "Revision deployment failed; HTTP ${deploy_status}."
    ;;
esac

deployment_record_succeeded() {
  local revision="$1"

  jq -e \
    --arg revision "$revision" '
      def items:
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

      any(
        items[]?;
        (
          (
            (.revisionUuid // .revisionId // "") == $revision
          ) or
          (
            (.revisionUuid // .revisionId // "") == ""
          )
        ) and
        (
          ((.deployedGatewayCount // 0) > 0) or
          ((.successDeployedTime // "") != "")
        )
      )
    ' >/dev/null 2>&1
}

deployment_record_rejected() {
  jq -e '
    def items:
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

    any(
      items[]?;
      (.status // "") == "REJECTED" or
      ((.failedGatewayCount // 0) > 0)
    )
  ' >/dev/null 2>&1
}

deployment_record_pending() {
  jq -e '
    def items:
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

    any(
      items[]?;
      (.status // "") == "CREATED"
    )
  ' >/dev/null 2>&1
}

gateway_route_exists() {
  local status

  status="$(
    curl -ksS \
      -o "$WORK_DIR/gateway-probe.json" \
      -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      "https://127.0.0.1:8243${API_CONTEXT}/number-verifications" ||
      true
  )"

  case "$status" in
    401|403)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

echo "[oauth-api-deployment] Deploy-revision response:"

if jq . "$WORK_DIR/deploy.json" >/dev/null 2>&1; then
  jq . "$WORK_DIR/deploy.json"
else
  cat "$WORK_DIR/deploy.json"
fi

deploy_response="$(
  cat "$WORK_DIR/deploy.json"
)"

if deployment_record_rejected <<<"$deploy_response"; then
  fail "APIM rejected the revision deployment."
fi

for attempt in $(seq 1 45); do
  deployments="$(
    curl -kfsS \
      -H "Authorization: Bearer ${token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
  )"

  revisions="$(
    curl -kfsS \
      -H "Authorization: Bearer ${token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions?limit=100"
  )"

  revision_deployments="$(
    jq -c \
      --arg revision "$revision_id" '
        [
          (.list // .data // [])[]?
          | select(
              (.id // .revisionId // "") == $revision
            )
          | (.deploymentInfo // [])[]?
        ]
      ' \
      <<<"$revisions"
  )"

  if deployment_record_rejected <<<"$deployments" ||
     deployment_record_rejected <<<"$revision_deployments"
  then
    echo "[oauth-api-deployment] Deployment endpoint:" >&2
    jq . <<<"$deployments" >&2 || printf '%s\n' "$deployments" >&2

    echo "[oauth-api-deployment] Revision deployment information:" >&2
    jq . <<<"$revision_deployments" >&2 ||
      printf '%s\n' "$revision_deployments" >&2

    fail "Gateway revision deployment was rejected or failed."
  fi

  if deployment_record_succeeded "$revision_id" <<<"$deployments" ||
     deployment_record_succeeded "$revision_id" <<<"$revision_deployments"
  then
    log "Revision ${revision_id} is deployed according to the Publisher control plane."
    exit 0
  fi

  if gateway_route_exists; then
    log "Revision ${revision_id} is active on the Gateway."

    echo "[oauth-api-deployment] Gateway probe returned an OAuth rejection, confirming that the API route exists."
    exit 0
  fi

  if deployment_record_pending <<<"$deploy_response" ||
     deployment_record_pending <<<"$deployments" ||
     deployment_record_pending <<<"$revision_deployments"
  then
    log "Revision deployment is pending approval or gateway synchronization (${attempt}/45)."
  else
    log "Waiting for deployment state (${attempt}/45)."
  fi

  sleep 2
done

echo "[oauth-api-deployment] Final deploy-revision response:" >&2
jq . <<<"$deploy_response" >&2 ||
  printf '%s\n' "$deploy_response" >&2

echo "[oauth-api-deployment] Final deployment endpoint response:" >&2
jq . <<<"$deployments" >&2 ||
  printf '%s\n' "$deployments" >&2

echo "[oauth-api-deployment] Final revision deployment information:" >&2
jq . <<<"$revision_deployments" >&2 ||
  printf '%s\n' "$revision_deployments" >&2

if deployment_record_pending <<<"$deploy_response" ||
   deployment_record_pending <<<"$deployments" ||
   deployment_record_pending <<<"$revision_deployments"
then
  fail "Revision deployment remains in CREATED status. Check Admin Portal workflow approvals for REVISION_DEPLOYMENT."
fi

fail "Revision deployment did not converge and the API route is absent from the Gateway."

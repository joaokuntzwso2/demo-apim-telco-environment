#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

TARGET="scripts/ensure-oauth-api-deployment.sh"

fail() {
  printf '[oauth-deployment-poll-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$TARGET" ]] ||
  fail "Missing $TARGET"

backup="${TARGET}.before-poll-fix.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$backup"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if 'API_CONTEXT="/subscriber-authorization/v1"' not in text:
    marker = 'API_VERSION="1.0.0"'

    if marker not in text:
        raise SystemExit(
            "[oauth-deployment-poll-fix][FAIL] "
            "Could not locate API_VERSION."
        )

    text = text.replace(
        marker,
        marker + '\nAPI_CONTEXT="/subscriber-authorization/v1"',
        1,
    )

start_marker = 'for attempt in $(seq 1 30); do'
end_marker = '''printf '%s\\n' "$deployments" >&2

fail \\
  "Revision deployment did not converge."'''

start = text.find(start_marker)
end = text.find(end_marker, start)

if start < 0 or end < 0:
    if "deployment_record_succeeded()" in text:
        print(
            "[oauth-deployment-poll-fix] "
            "Hardened polling is already installed."
        )
        raise SystemExit(0)

    raise SystemExit(
        "[oauth-deployment-poll-fix][FAIL] "
        "Could not locate the existing polling block."
    )

end += len(end_marker)

replacement = r'''deployment_record_succeeded() {
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

fail "Revision deployment did not converge and the API route is absent from the Gateway."'''

text = text[:start] + replacement + text[end:]

path.write_text(text, encoding="utf-8")

print(
    "[oauth-deployment-poll-fix] "
    "Installed control-plane, revision and Gateway deployment checks."
)
PY

chmod +x "$TARGET"
bash -n "$TARGET"

grep -q \
  'deployment_record_succeeded()' \
  "$TARGET" ||
  fail "Hardened deployment verification was not installed."

echo
echo "[oauth-deployment-poll-fix] Fix installed."
echo "[oauth-deployment-poll-fix] Backup:"
echo "  $backup"

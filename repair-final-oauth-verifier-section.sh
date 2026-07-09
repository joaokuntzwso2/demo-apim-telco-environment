#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
INSTALLER="install-final-oauth-runtime-logic.sh"
NORMALIZER="scripts/normalize-oauth-verifier-api-section.py"

log() {
  printf '[oauth-verifier-section-repair] %s\n' "$*"
}

fail() {
  printf '[oauth-verifier-section-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 is required."

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-verifier-section-${timestamp}"

mkdir -p "$backup_dir"

cp "$VERIFY" \
  "$backup_dir/verify-oauth-consent-risk-controls.sh"

if [[ -f "$INSTALLER" ]]; then
  cp "$INSTALLER" \
    "$backup_dir/install-final-oauth-runtime-logic.sh"
fi

log "Backups written under $backup_dir"

cat > "$NORMALIZER" <<'PY'
#!/usr/bin/env python3

from pathlib import Path
import sys


def fail(message: str) -> None:
    print(
        f"[oauth-verifier-normalizer][FAIL] {message}",
        file=sys.stderr,
    )
    raise SystemExit(1)


if len(sys.argv) != 2:
    fail(
        "Usage: normalize-oauth-verifier-api-section.py "
        "<verify-script>"
    )

path = Path(sys.argv[1])

if not path.exists():
    fail(f"File does not exist: {path}")

text = path.read_text(encoding="utf-8")

start_marker = (
    'echo "[oauth-controls-verify] '
    'Checking API, scopes, deployment and documents."'
)

end_marker = (
    'echo "[oauth-controls-verify] '
    'Checking native subscription policies."'
)

start = text.find(start_marker)
end = text.find(end_marker, start)

if start < 0:
    fail(
        "Could not locate the API/scope/deployment section header."
    )

if end < 0:
    fail(
        "Could not locate the native subscription-policy section header."
    )

section = r'''echo "[oauth-controls-verify] Checking API, scopes, deployment and documents."

apis="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

api_id="$(
  jq -r '
    first(
      (.list // .data // [])[]?
      | select(
          .name == "SubscriberAuthorizationControlAPI" and
          (.version // "") == "1.0.0"
        )
      | .id
    ) // empty
  ' <<<"${apis}"
)"

if [[ -z "${api_id}" ]]; then
  fail "SubscriberAuthorizationControlAPI:1.0.0 is absent."
else
  api="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}"
  )"

  api_lifecycle="$(
    jq -r '
      .lifeCycleStatus //
      .lifecycleStatus //
      .state //
      empty
    ' <<<"${api}"
  )"

  if [[ "${api_lifecycle}" == "PUBLISHED" ]]; then
    pass "Managed API is PUBLISHED."
  else
    fail "Managed API is not PUBLISHED (state=${api_lifecycle:-UNKNOWN})."
  fi

  for scope in \
    number-verification:read \
    sim-swap:read \
    device-location:verify \
    qod:request \
    commercial-usage:read
  do
    if jq -e \
      --arg scope "${scope}" '
        def scope_name:
          (
            .key //
            .name //
            .scope.name //
            .scope.key //
            ""
          );

        any(
          .scopes[]?;
          scope_name == $scope
        )
      ' <<<"${api}" >/dev/null
    then
      pass "Scope exists: ${scope}"
    else
      fail "Scope missing: ${scope}"
    fi
  done

  for scope_role in \
    'number-verification:read|telco_partner' \
    'number-verification:read|telco_operations' \
    'number-verification:read|telco_platform_admin' \
    'sim-swap:read|telco_partner' \
    'sim-swap:read|telco_operations' \
    'sim-swap:read|telco_platform_admin' \
    'device-location:verify|telco_partner' \
    'device-location:verify|telco_operations' \
    'device-location:verify|telco_platform_admin' \
    'qod:request|telco_partner' \
    'qod:request|telco_operations' \
    'qod:request|telco_platform_admin' \
    'commercial-usage:read|telco_partner' \
    'commercial-usage:read|telco_operations' \
    'commercial-usage:read|telco_product_manager' \
    'commercial-usage:read|telco_platform_admin'
  do
    scope_key="${scope_role%%|*}"
    expected_role="${scope_role#*|}"

    if jq -e \
      --arg scope "${scope_key}" \
      --arg role "${expected_role}" '
        def scope_name:
          (
            .key //
            .name //
            .scope.name //
            .scope.key //
            ""
          );

        def normalized_bindings:
          (
            .roles //
            .bindings //
            .scope.bindings //
            .scope.roles //
            []
          )
          | if type == "string"
            then split(",")
            else .
            end
          | map(
              tostring
              | gsub("^\\s+|\\s+$"; "")
              | sub("^Internal/"; "")
              | sub("^PRIMARY/"; "")
            );

        any(
          .scopes[]?;
          scope_name == $scope and
          (
            (
              normalized_bindings
              | index($role)
            ) != null
          )
        )
      ' <<<"${api}" >/dev/null
    then
      pass "Scope role binding exists: ${scope_key} -> ${expected_role}."
    else
      fail "Scope role binding missing: ${scope_key} -> ${expected_role}."
    fi
  done

  deployment_log="${WORK_DIR}/oauth-api-deployment-check.log"

  if bash scripts/check-oauth-api-deployment.sh \
      >"${deployment_log}" 2>&1
  then
    pass "API has a deployed revision."
  else
    fail "API has no deployed revision."

    if [[ -s "${deployment_log}" ]]; then
      cat "${deployment_log}" >&2
    fi
  fi

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/documents?limit=100"
  )"

  for doc in \
    '10 - OAuth Scopes and Personas' \
    '11 - Consent Purpose Country and Partner Isolation' \
    '12 - Security Error and Verification Catalogue'
  do
    if jq -e \
      --arg doc "${doc}" '
        any(
          (.list // .data // [])[]?;
          .name == $doc
        )
      ' <<<"${docs}" >/dev/null
    then
      pass "Developer Portal document exists: ${doc}"
    else
      fail "Developer Portal document missing: ${doc}"
    fi
  done
fi

'''

updated = text[:start] + section + text[end:]

path.write_text(
    updated,
    encoding="utf-8",
)

print(
    "[oauth-verifier-normalizer] "
    "Replaced the complete API/scope/deployment/document section."
)
PY

chmod +x "$NORMALIZER"

python3 "$NORMALIZER" "$VERIFY"

if ! bash -n "$VERIFY"; then
  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  fail \
    "The normalized verifier failed Bash validation; original restored."
fi

log "Verifier syntax is valid."

###############################################################################
# Replace the defective section-replacement algorithm in the final installer.
###############################################################################

if [[ -f "$INSTALLER" ]]; then
  python3 - "$INSTALLER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start_marker = '''###############################################################################
# 5. Make the verifier use the authoritative read-only deployment checker
###############################################################################
'''

end_marker = '''###############################################################################
# 6. Validate every generated artifact before execution
###############################################################################
'''

start = text.find(start_marker)
end = text.find(end_marker, start)

if start < 0:
    raise SystemExit(
        "[oauth-verifier-section-repair][FAIL] "
        "Could not locate installer section 5."
    )

if end < 0:
    raise SystemExit(
        "[oauth-verifier-section-repair][FAIL] "
        "Could not locate installer section 6."
    )

replacement = '''###############################################################################
# 5. Normalize the complete verifier API/scope/deployment/document section
###############################################################################

python3 scripts/normalize-oauth-verifier-api-section.py "$VERIFY"

'''

updated = text[:start] + replacement + text[end:]

path.write_text(
    updated,
    encoding="utf-8",
)

print(
    "[oauth-verifier-section-repair] "
    "Replaced the installer's unsafe backward-if search."
)
PY

  if ! bash -n "$INSTALLER"; then
    cp \
      "$backup_dir/install-final-oauth-runtime-logic.sh" \
      "$INSTALLER"

    fail \
      "The repaired installer failed Bash validation; original restored."
  fi

  log "Final installer syntax is valid."
fi

echo
echo "[oauth-verifier-section-repair] Repaired verifier section:"
section_line="$(
  grep -n \
    'Checking API, scopes, deployment and documents' \
    "$VERIFY" |
    head -n 1 |
    cut -d: -f1
)"

if [[ -n "$section_line" ]]; then
  end_line=$((section_line + 190))

  sed -n "${section_line},${end_line}p" "$VERIFY"
fi

cat <<EOF

[oauth-verifier-section-repair] Repair completed.

Backups:
  ${backup_dir}

Static validation:

  bash -n scripts/verify-oauth-consent-risk-controls.sh
  bash -n install-final-oauth-runtime-logic.sh

Continue the installation:

  bash install-final-oauth-runtime-logic.sh

EOF

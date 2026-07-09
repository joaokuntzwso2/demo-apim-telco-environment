#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"

INSTALLER_FILES=(
  "install-oauth-consent-risk-controls.sh"
  "install-oauth-consent-risk-controls-v2.sh"
)

log() {
  printf '[oauth-expiry-final-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-expiry-final-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-expiry-final-${timestamp}"

mkdir -p "$backup_dir"

cp "$VERIFY" \
  "$backup_dir/verify-oauth-consent-risk-controls.sh"

for installer in "${INSTALLER_FILES[@]}"; do
  if [[ -f "$installer" ]]; then
    cp \
      "$installer" \
      "$backup_dir/$(basename "$installer")"
  fi
done

log "Backups written under $backup_dir"

cat > /tmp/patch-oauth-expiry-verifier.py <<'PY'
#!/usr/bin/env python3

from pathlib import Path
import sys


def abort(message: str) -> None:
    print(
        f"[oauth-expiry-final-fix][FAIL] {message}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def add_python_requirement(lines: list[str]) -> list[str]:
    updated = []

    for line in lines:
        stripped = line.strip()

        if (
            stripped.startswith("for command in ")
            and "curl" in stripped
            and "jq" in stripped
            and "docker" in stripped
            and "python3" not in stripped
        ):
            before, separator, after = line.partition("; do")

            if not separator:
                updated.append(line)
                continue

            line = before.rstrip() + " python3; do" + after

        updated.append(line)

    return updated


def patch_expiry_section(text: str, filename: str) -> str:
    lines = text.splitlines()

    if (
        "validity_period=2" in text
        and "JWT lifetime=" in text
        and "Direct two-second OAuth token" in text
    ):
        print(
            f"[oauth-expiry-final-fix] "
            f"{filename} already contains the final expiry test."
        )

        return text

    missing_scope_failure = next(
        (
            index
            for index, line in enumerate(lines)
            if (
                "Missing-scope request expected HTTP 403"
                in line
            )
        ),
        None,
    )

    if missing_scope_failure is None:
        abort(
            f"Could not locate the missing-scope test in {filename}."
        )

    start = None

    for index in range(
        missing_scope_failure + 1,
        len(lines),
    ):
        if lines[index].strip() == "fi":
            start = index + 1
            break

    if start is None:
        abort(
            f"Could not locate the end of the missing-scope "
            f"test in {filename}."
        )

    end = next(
        (
            index
            for index in range(start, len(lines))
            if lines[index].startswith("country_payload=")
        ),
        None,
    )

    if end is None:
        abort(
            f"Could not locate country_payload after the "
            f"expiry test in {filename}."
        )

    old_section = "\n".join(lines[start:end])

    expected_markers = (
        "short_token",
        "expired_client_id",
        "expired_client_secret",
    )

    missing_markers = [
        marker
        for marker in expected_markers
        if marker not in old_section
    ]

    if missing_markers:
        abort(
            f"The detected expiry section in {filename} is "
            f"missing expected markers: "
            + ", ".join(missing_markers)
        )

    replacement = r'''
#
# WSO2's Developer Portal generate-token operation uses the OAuth
# application's configured/default lifetime. It does not forward a per-request
# validity period to the resident Key Manager token endpoint.
#
# Request the deterministic two-second application token directly from the
# native OAuth endpoint using WSO2's supported validity_period parameter.
#
short_token_json="$(
  curl -ksS \
    -u "${expired_client_id}:${expired_client_secret}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode 'scope=number-verification:read' \
    --data-urlencode 'validity_period=2' \
    "${APIM_URL}/oauth2/token"
)"

short_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"${short_token_json}"
)"

expires_in="$(
  jq -r \
    '.expires_in // 0' \
    <<<"${short_token_json}"
)"

jwt_lifetime="$(
  python3 - "${short_token}" <<'JWT_LIFETIME'
import base64
import json
import sys

token = sys.argv[1]

if not token:
    print(0)
    raise SystemExit(0)

parts = token.split(".")

if len(parts) < 2:
    print(0)
    raise SystemExit(0)

payload = parts[1]
payload += "=" * ((4 - len(payload) % 4) % 4)

try:
    claims = json.loads(
        base64.urlsafe_b64decode(
            payload.encode("ascii")
        ).decode("utf-8")
    )

    issued_at = int(claims.get("iat", 0))
    expires_at = int(claims.get("exp", 0))

    if issued_at <= 0 or expires_at <= 0:
        print(0)
    else:
        print(expires_at - issued_at)

except Exception:
    print(0)
JWT_LIFETIME
)"

if [[ -z "${short_token}" ]]; then
  fail "Direct two-second OAuth token was not issued."

  printf '%s\n' \
    "${short_token_json}" >&2

elif ! [[ "${expires_in}" =~ ^[0-9]+$ ]]; then
  fail \
    "Direct short-lived token returned invalid expires_in=${expires_in}."

  printf '%s\n' \
    "${short_token_json}" >&2

elif ! [[ "${jwt_lifetime}" =~ ^[0-9]+$ ]]; then
  fail \
    "Could not determine the direct short-lived JWT lifetime."

elif (( expires_in < 1 || expires_in > 2 )); then
  fail \
    "Direct short-lived token returned expires_in=${expires_in}; expected 1-2 seconds."

  printf '%s\n' \
    "${short_token_json}" >&2

elif (( jwt_lifetime < 1 || jwt_lifetime > 2 )); then
  fail \
    "Direct short-lived JWT lifetime=${jwt_lifetime}; expected 1-2 seconds."

  printf '%s\n' \
    "${short_token_json}" >&2

else
  pass \
    "Direct two-second OAuth token issued (expires_in=${expires_in}, JWT lifetime=${jwt_lifetime})."

  #
  # Five seconds gives both the authorization server and Gateway a clear
  # margin beyond the requested two-second expiration.
  #
  sleep 5

  expired_status="$(
    invoke \
      "${short_token}" \
      '/number-verifications' \
      "${valid_payload}" \
      'oauth-controls-expired-001'
  )"

  if [[ "${expired_status}" == "401" ]]; then
    pass \
      "Dedicated two-second APIM token rejected after expiration."
  else
    fail \
      "Expired token expected HTTP 401, received ${expired_status}; expires_in=${expires_in}, JWT lifetime=${jwt_lifetime}."

    cat \
      "${WORK_DIR}/body.json" >&2
  fi
fi

'''.strip("\n").splitlines()

    lines = (
        lines[:start]
        + replacement
        + lines[end:]
    )

    lines = add_python_requirement(lines)

    updated = "\n".join(lines) + "\n"

    print(
        f"[oauth-expiry-final-fix] "
        f"Replaced the complete expiry section in {filename}."
    )

    return updated


def patch_file(path: Path, required: bool) -> None:
    if not path.exists():
        if required:
            abort(f"Required file is missing: {path}")

        return

    text = path.read_text(encoding="utf-8")

    updated = patch_expiry_section(
        text,
        str(path),
    )

    path.write_text(
        updated,
        encoding="utf-8",
    )


patch_file(
    Path(sys.argv[1]),
    required=True,
)

for filename in sys.argv[2:]:
    patch_file(
        Path(filename),
        required=False,
    )
PY

python3 \
  /tmp/patch-oauth-expiry-verifier.py \
  "$VERIFY" \
  "${INSTALLER_FILES[@]}"

rm -f /tmp/patch-oauth-expiry-verifier.py

log "Validating generated shell syntax."

if ! bash -n "$VERIFY"; then
  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  fail \
    "Verifier syntax validation failed; original verifier restored."
fi

for installer in "${INSTALLER_FILES[@]}"; do
  if [[ -f "$installer" ]]; then
    if ! bash -n "$installer"; then
      cp \
        "$backup_dir/$(basename "$installer")" \
        "$installer"

      fail \
        "Installer validation failed: $installer"
    fi
  fi
done

grep -Fq \
  "--data-urlencode 'validity_period=2'" \
  "$VERIFY" ||
  fail \
    "The direct token validity parameter is absent."

grep -Fq \
  'grant_type=client_credentials' \
  "$VERIFY" ||
  fail \
    "The direct client-credentials request is absent."

grep -Fq \
  'JWT lifetime=${jwt_lifetime}' \
  "$VERIFY" ||
  fail \
    "JWT lifetime validation is absent."

if grep -Fq \
  'Short-lived token returned validity=' \
  "$VERIFY"
then
  fail \
    "The obsolete Developer Portal validityTime assertion remains."
fi

log "Static validation passed."

echo
echo "[oauth-expiry-final-fix] Installed expiry request:"
grep -n \
  -A 10 \
  -B 3 \
  "validity_period=2" \
  "$VERIFY"
echo

if [[ "${RUN_VERIFY:-1}" == "1" ]]; then
  log "Running the verifier directly; no reconciliation or rebuild is needed."

  bash "$VERIFY"
fi

cat <<EOF

[oauth-expiry-final-fix] Completed.

Backups:
  ${backup_dir}

The expiry scenario now uses:
  POST ${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}/oauth2/token
  grant_type=client_credentials
  validity_period=2

EOF

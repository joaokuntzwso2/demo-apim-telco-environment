#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"

log() {
  printf '[oauth-expiry-boundary-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-expiry-boundary-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 jq curl; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-expiry-boundary-${timestamp}"

mkdir -p "$backup_dir"
cp "$VERIFY" "$backup_dir/verify-oauth-consent-risk-controls.sh"

log "Backup written to $backup_dir"

python3 - "$VERIFY" <<'PY_PATCH'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

if (
    "validity_period=2" in "\n".join(lines)
    and "Extracting the short-lived OAuth credentials" in "\n".join(lines)
):
    print(
        "[oauth-expiry-boundary-fix] "
        "Final expiry test is already installed."
    )
    raise SystemExit(0)

pass_index = next(
    (
        index
        for index, line in enumerate(lines)
        if "Missing-scope request rejected by APIM." in line
    ),
    None,
)

if pass_index is None:
    raise SystemExit(
        "[oauth-expiry-boundary-fix][FAIL] "
        "Could not find the missing-scope PASS statement."
    )

# The first standalone fi after the PASS closes the missing-scope test.
start = None

for index in range(pass_index + 1, len(lines)):
    if lines[index].strip() == "fi":
        start = index + 1
        break

if start is None:
    raise SystemExit(
        "[oauth-expiry-boundary-fix][FAIL] "
        "Could not find the end of the missing-scope test."
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
    raise SystemExit(
        "[oauth-expiry-boundary-fix][FAIL] "
        "Could not find country_payload after the expiry test."
    )

old_section = "\n".join(lines[start:end])

if "short" not in old_section.lower():
    raise SystemExit(
        "[oauth-expiry-boundary-fix][FAIL] "
        "The detected section does not look like the expiry test."
    )

replacement = r'''
#
# Deterministic token-expiration verification.
#
# The Developer Portal generate-token operation applies the OAuth
# application's configured/default lifetime. For an exact two-second runtime
# test, call the WSO2 token endpoint directly with validity_period=2.
#
log "Requesting a deterministic two-second client-credentials token."

oauth_state_payload=""

for oauth_state_variable in \
  state_json \
  state \
  bootstrap_state \
  oauth_state
do
  if declare -p "${oauth_state_variable}" >/dev/null 2>&1; then
    oauth_state_candidate="${!oauth_state_variable}"

    if jq -e . \
      <<<"${oauth_state_candidate}" \
      >/dev/null 2>&1
    then
      oauth_state_payload="${oauth_state_candidate}"
      break
    fi
  fi
done

if [[ -z "${oauth_state_payload}" ]]; then
  fail \
    "Could not locate the loaded OAuth bootstrap-state JSON."
else
  expiry_state_file="${WORK_DIR}/oauth-expiry-state.json"

  printf '%s\n' \
    "${oauth_state_payload}" \
    >"${expiry_state_file}"

  log "Extracting the short-lived OAuth credentials from bootstrap state."

  expiry_credentials="$(
    python3 - "${expiry_state_file}" <<'PY_CREDENTIALS'
import json
import re
import sys
from pathlib import Path

state_path = Path(sys.argv[1])

try:
    state = json.loads(
        state_path.read_text(encoding="utf-8")
    )
except Exception as error:
    print(
        f"Could not parse OAuth state: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def scalar_text(value):
    if value is None:
        return ""

    if isinstance(value, (str, int, float, bool)):
        return str(value)

    if isinstance(value, list):
        return " ".join(
            scalar_text(item)
            for item in value
        )

    if isinstance(value, dict):
        return " ".join(
            f"{key} {scalar_text(child)}"
            for key, child in value.items()
        )

    return ""


def find_case_insensitive(obj, expected):
    expected = expected.lower()

    for key, value in obj.items():
        if str(key).lower() == expected:
            return value

    return None


def credential_pairs(obj):
    explicit_pairs = (
        ("consumerKey", "consumerSecret"),
        ("consumer_key", "consumer_secret"),
        ("clientId", "clientSecret"),
        ("client_id", "client_secret"),
        ("expiredClientId", "expiredClientSecret"),
        ("shortLivedClientId", "shortLivedClientSecret"),
        ("verificationClientId", "verificationClientSecret"),
    )

    found = []

    for key_name, secret_name in explicit_pairs:
        key_value = find_case_insensitive(
            obj,
            key_name,
        )

        secret_value = find_case_insensitive(
            obj,
            secret_name,
        )

        if (
            isinstance(key_value, str)
            and key_value
            and isinstance(secret_value, str)
            and secret_value
        ):
            found.append(
                (
                    key_value,
                    secret_value,
                )
            )

    # Also support prefixed field names such as expiryConsumerKey.
    lower_keys = {
        str(key).lower(): key
        for key in obj
    }

    for key, value in obj.items():
        if not isinstance(value, str) or not value:
            continue

        lower_key = str(key).lower()

        if lower_key.endswith("consumerkey"):
            secret_key = (
                lower_key[:-len("consumerkey")]
                + "consumersecret"
            )

        elif lower_key.endswith("clientid"):
            secret_key = (
                lower_key[:-len("clientid")]
                + "clientsecret"
            )

        elif lower_key.endswith("consumer_key"):
            secret_key = (
                lower_key[:-len("consumer_key")]
                + "consumer_secret"
            )

        elif lower_key.endswith("client_id"):
            secret_key = (
                lower_key[:-len("client_id")]
                + "client_secret"
            )

        else:
            continue

        original_secret_key = lower_keys.get(
            secret_key
        )

        if original_secret_key is None:
            continue

        secret = obj.get(original_secret_key)

        if isinstance(secret, str) and secret:
            found.append(
                (
                    value,
                    secret,
                )
            )

    unique = []
    seen = set()

    for pair in found:
        if pair in seen:
            continue

        seen.add(pair)
        unique.append(pair)

    return unique


candidates = []


def walk(value, path=(), inherited_labels=()):
    if isinstance(value, dict):
        labels = list(inherited_labels)

        for label_key in (
            "name",
            "applicationName",
            "displayName",
            "description",
            "purpose",
            "type",
            "persona",
            "keyType",
        ):
            label_value = find_case_insensitive(
                value,
                label_key,
            )

            if isinstance(label_value, str):
                labels.append(label_value)

        object_text = scalar_text(value).lower()
        path_text = "/".join(path).lower()
        label_text = " ".join(labels).lower()

        combined = (
            path_text
            + " "
            + label_text
            + " "
            + object_text
        )

        score = 0

        marker_weights = {
            "two-second": 100,
            "two second": 100,
            "short-lived": 90,
            "short lived": 90,
            "shortlived": 90,
            "expiry": 70,
            "expired": 70,
            "expiration": 60,
            "verification": 30,
        }

        for marker, weight in marker_weights.items():
            if marker in combined:
                score += weight

        if "client_credentials" in combined:
            score += 15

        expiry_keys = (
            "validitytime",
            "applicationaccesstokenexpirytime",
            "useraccesstokenexpirytime",
            "tokenvalidity",
            "validityperiod",
        )

        for key, child in value.items():
            normalized_key = re.sub(
                r"[^a-z0-9]",
                "",
                str(key).lower(),
            )

            if normalized_key in expiry_keys:
                try:
                    if int(child) == 2:
                        score += 120
                except Exception:
                    pass

        for client_id, client_secret in credential_pairs(
            value
        ):
            candidates.append(
                {
                    "score": score,
                    "path": "/".join(path),
                    "client_id": client_id,
                    "client_secret": client_secret,
                }
            )

        for key, child in value.items():
            walk(
                child,
                path + (str(key),),
                tuple(labels),
            )

    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(
                child,
                path + (str(index),),
                inherited_labels,
            )


walk(state)

if not candidates:
    print(
        "No OAuth client credentials were found in state.",
        file=sys.stderr,
    )
    raise SystemExit(1)

candidates.sort(
    key=lambda candidate: candidate["score"],
    reverse=True,
)

winner = candidates[0]

if winner["score"] <= 0:
    print(
        "OAuth clients were found, but none was identifiable "
        "as the short-lived verification client.",
        file=sys.stderr,
    )

    for candidate in candidates:
        print(
            f"candidate path={candidate['path']!r} "
            f"score={candidate['score']}",
            file=sys.stderr,
        )

    raise SystemExit(1)

if (
    len(candidates) > 1
    and candidates[1]["score"] == winner["score"]
    and candidates[1]["client_id"] != winner["client_id"]
):
    print(
        "Multiple OAuth clients have the same highest "
        "short-lived-client score.",
        file=sys.stderr,
    )

    for candidate in candidates[:5]:
        print(
            f"candidate path={candidate['path']!r} "
            f"score={candidate['score']}",
            file=sys.stderr,
        )

    raise SystemExit(1)

print(
    json.dumps(
        {
            "client_id": winner["client_id"],
            "client_secret": winner["client_secret"],
            "path": winner["path"],
        },
        separators=(",", ":"),
    )
)
PY_CREDENTIALS
  )"

  short_client_id="$(
    jq -r \
      '.client_id // empty' \
      <<<"${expiry_credentials}"
  )"

  short_client_secret="$(
    jq -r \
      '.client_secret // empty' \
      <<<"${expiry_credentials}"
  )"

  short_client_path="$(
    jq -r \
      '.path // empty' \
      <<<"${expiry_credentials}"
  )"

  if [[ -z "${short_client_id}" ||
        -z "${short_client_secret}" ]]
  then
    fail \
      "Short-lived OAuth consumer credentials could not be resolved."
  else
    log \
      "Resolved the short-lived OAuth client from state path: ${short_client_path:-unknown}"

    short_token_url="${
      OAUTH_SHORT_TOKEN_URL:-
      https://127.0.0.1:8243/token
    }"

    short_token_json="$(
      curl -ksS \
        -u "${short_client_id}:${short_client_secret}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode 'scope=default' \
        --data-urlencode 'validity_period=2' \
        "${short_token_url}"
    )"

    short_token="$(
      jq -r \
        '.access_token // .accessToken // empty' \
        <<<"${short_token_json}"
    )"

    expires_in="$(
      jq -r \
        '.expires_in // .validityTime // 0' \
        <<<"${short_token_json}"
    )"

    jwt_lifetime="$(
      python3 - "${short_token}" <<'PY_JWT'
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
payload += "=" * (
    (4 - len(payload) % 4) % 4
)

try:
    claims = json.loads(
        base64.urlsafe_b64decode(
            payload.encode("ascii")
        ).decode("utf-8")
    )

    issued_at = int(
        claims.get("iat", 0)
    )

    expires_at = int(
        claims.get("exp", 0)
    )

    if issued_at <= 0 or expires_at <= 0:
        print(0)
    else:
        print(expires_at - issued_at)

except Exception:
    print(0)
PY_JWT
    )"

    if [[ -z "${short_token}" ]]; then
      fail \
        "The WSO2 token endpoint did not issue the two-second token."

      jq \
        'del(.access_token, .accessToken, .refresh_token)' \
        <<<"${short_token_json}" >&2 ||
        true

    elif ! [[ "${expires_in}" =~ ^[0-9]+$ ]]; then
      fail \
        "Short-lived token returned invalid expires_in=${expires_in}."

    elif ! [[ "${jwt_lifetime}" =~ ^[0-9]+$ ]]; then
      fail \
        "Short-lived token returned an invalid JWT lifetime."

    elif (( expires_in < 1 || expires_in > 2 )); then
      fail \
        "Short-lived token returned expires_in=${expires_in}; expected 1-2 seconds."

      jq \
        'del(.access_token, .accessToken, .refresh_token)' \
        <<<"${short_token_json}" >&2 ||
        true

    elif (( jwt_lifetime < 1 || jwt_lifetime > 2 )); then
      fail \
        "Short-lived JWT lifetime=${jwt_lifetime}; expected 1-2 seconds."

    else
      pass \
        "Direct two-second OAuth token issued (expires_in=${expires_in}, JWT lifetime=${jwt_lifetime})."

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
          "Expired token expected HTTP 401, received ${expired_status}."

        cat \
          "${WORK_DIR}/body.json" >&2
      fi
    fi
  fi
fi

'''.strip("\n").splitlines()

updated = (
    lines[:start]
    + replacement
    + lines[end:]
)

path.write_text(
    "\n".join(updated) + "\n",
    encoding="utf-8",
)

print(
    "[oauth-expiry-boundary-fix] "
    f"Replaced verifier lines {start + 1}-{end}."
)
PY_PATCH

if ! bash -n "$VERIFY"; then
  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  fail "Verifier syntax failed; original verifier restored."
fi

grep -Fq \
  "validity_period=2" \
  "$VERIFY" ||
  fail "validity_period=2 was not installed."

grep -Fq \
  "Extracting the short-lived OAuth credentials" \
  "$VERIFY" ||
  fail "State-based client discovery was not installed."

if grep -Fq \
  "Short-lived token returned validity=" \
  "$VERIFY"
then
  fail "The obsolete Developer Portal validity check remains."
fi

log "Verifier repair passed static validation."
log "Running the verifier directly."

bash "$VERIFY"

cat <<EOF

[oauth-expiry-boundary-fix] Complete verification passed.

Backup:
  ${backup_dir}

No image rebuild, reconciliation, APIM restart, or MI restart was performed.

EOF

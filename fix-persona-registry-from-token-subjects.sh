#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

GENERATOR="scripts/generate-oauth-persona-sequence.sh"
RESOLVER="scripts/resolve-oauth-persona-subjects.py"
INSTALLER="install-final-oauth-runtime-logic.sh"
SETUP_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"

log() {
  printf '[oauth-persona-subject-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-persona-subject-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 jq curl docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$GENERATOR" \
  "$SETUP_JS" \
  "$VERIFY" \
  scripts/read-oauth-business-state.sh \
  scripts/oauth-compose-context.sh
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-persona-subject-${timestamp}"

mkdir -p "$backup_dir"

cp \
  "$GENERATOR" \
  "$backup_dir/generate-oauth-persona-sequence.sh"

if [[ -f "$INSTALLER" ]]; then
  cp \
    "$INSTALLER" \
    "$backup_dir/install-final-oauth-runtime-logic.sh"
fi

log "Backups written under $backup_dir"

###############################################################################
# Resolve each user's authoritative UUID by issuing a real password-grant
# token and decoding its sub claim.
###############################################################################

cat > "$RESOLVER" <<'PY'
#!/usr/bin/env python3

import base64
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

USERNAMES = (
    "partner.alpha",
    "partner.beta",
    "telco.operations",
    "telco.product",
    "telco.admin",
)

PASSWORD_KEYS = (
    "password",
    "userPassword",
    "user_password",
    "credential",
)

CLIENT_KEY_PAIRS = (
    ("consumerKey", "consumerSecret"),
    ("consumer_key", "consumer_secret"),
    ("clientId", "clientSecret"),
    ("client_id", "client_secret"),
)

UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-"
    r"[0-9a-f]{4}-"
    r"[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-"
    r"[0-9a-f]{12}$",
    re.IGNORECASE,
)


def fail(message):
    print(
        f"[oauth-persona-subjects][FAIL] {message}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def walk(value, path=()):
    if isinstance(value, dict):
        yield path, value

        for key, child in value.items():
            yield from walk(
                child,
                path + (str(key),),
            )

    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(
                child,
                path + (str(index),),
            )


def scalar_text(value):
    if value is None:
        return ""

    if isinstance(
        value,
        (str, int, float, bool),
    ):
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


def object_mentions_username(obj, username):
    for key in (
        "username",
        "userName",
        "user",
        "login",
    ):
        value = obj.get(key)

        if (
            isinstance(value, str)
            and value.lower() == username.lower()
        ):
            return True

    return (
        username.lower()
        in scalar_text(obj).lower()
    )


def resolve_source_expression(source, expression):
    expression = (
        expression
        .strip()
        .rstrip(",")
    )

    literal = re.fullmatch(
        r"""(['"`])([^'"`]*)\1""",
        expression,
        re.DOTALL,
    )

    if literal:
        return literal.group(2)

    if not re.fullmatch(
        r"[A-Za-z_$][A-Za-z0-9_$]*",
        expression,
    ):
        return None

    variable = expression

    patterns = (
        rf"""
        \b(?:const|let|var)\s+
        {re.escape(variable)}
        \s*=\s*
        (['"`])([^'"`]*)\1
        """,
        rf"""
        \b(?:const|let|var)\s+
        {re.escape(variable)}
        \s*=\s*
        process\.env\.[A-Za-z0-9_]+
        \s*\|\|\s*
        (['"`])([^'"`]*)\1
        """,
        rf"""
        \b(?:const|let|var)\s+
        {re.escape(variable)}
        \s*=\s*
        process\.env\[
          ['"][A-Za-z0-9_]+['"]
        \]
        \s*\|\|\s*
        (['"`])([^'"`]*)\1
        """,
    )

    for pattern in patterns:
        match = re.search(
            pattern,
            source,
            re.VERBOSE | re.DOTALL,
        )

        if match:
            return match.group(2)

    return None


def password_from_sources(source, username):
    username_positions = [
        match.start()
        for match in re.finditer(
            re.escape(username),
            source,
        )
    ]

    for username_position in username_positions:
        start = max(
            0,
            username_position - 1800,
        )

        end = min(
            len(source),
            username_position + 2200,
        )

        window = source[start:end]
        matches = []

        for key in PASSWORD_KEYS:
            pattern = (
                rf"\b{re.escape(key)}"
                rf"\s*:\s*"
                rf"([^,\n}}]+)"
            )

            for match in re.finditer(
                pattern,
                window,
            ):
                absolute_position = (
                    start + match.start()
                )

                distance = abs(
                    absolute_position
                    - username_position
                )

                matches.append(
                    (
                        distance,
                        match.group(1),
                    )
                )

        matches.sort(
            key=lambda item: item[0]
        )

        for _, expression in matches:
            value = resolve_source_expression(
                source,
                expression,
            )

            if value:
                return value

    return None


def find_password(state, source, username):
    candidates = []

    for path, obj in walk(state):
        if not object_mentions_username(
            obj,
            username,
        ):
            continue

        path_text = "/".join(path).lower()

        for key in PASSWORD_KEYS:
            value = obj.get(key)

            if (
                not isinstance(value, str)
                or not value
            ):
                continue

            score = 10

            if (
                "persona" in path_text
                or "user" in path_text
            ):
                score += 5

            if (
                obj.get("username") == username
                or obj.get("userName") == username
            ):
                score += 10

            candidates.append(
                (
                    score,
                    value,
                )
            )

    if candidates:
        candidates.sort(
            key=lambda item: item[0],
            reverse=True,
        )

        return candidates[0][1]

    value = password_from_sources(
        source,
        username,
    )

    if value:
        return value

    fail(
        f"Could not resolve the configured password "
        f"for {username} from OAuth state or source."
    )


def collect_oauth_clients(state):
    clients = []
    seen = set()

    for path, obj in walk(state):
        path_text = "/".join(path).lower()
        object_text = scalar_text(obj).lower()

        for key_field, secret_field in CLIENT_KEY_PAIRS:
            client_key = obj.get(key_field)
            client_secret = obj.get(secret_field)

            if (
                not isinstance(client_key, str)
                or not client_key
                or not isinstance(client_secret, str)
                or not client_secret
            ):
                continue

            identity = (
                client_key,
                client_secret,
            )

            if identity in seen:
                continue

            seen.add(identity)

            score = 0

            if "password" in object_text:
                score += 20

            if (
                "partner" in path_text
                or "operation" in path_text
            ):
                score += 10

            if (
                "production" in path_text
                or "production" in object_text
            ):
                score += 5

            if any(
                marker in path_text
                or marker in object_text
                for marker in (
                    "short",
                    "expiry",
                    "two-second",
                    "verification",
                )
            ):
                score -= 30

            clients.append(
                (
                    score,
                    client_key,
                    client_secret,
                )
            )

    clients.sort(
        key=lambda item: item[0],
        reverse=True,
    )

    return clients


def decode_jwt(token):
    parts = token.split(".")

    if len(parts) < 2:
        return {}

    payload = parts[1]
    payload += "=" * (
        (4 - len(payload) % 4) % 4
    )

    try:
        decoded = base64.urlsafe_b64decode(
            payload.encode("ascii")
        )

        result = json.loads(
            decoded.decode("utf-8")
        )

        if isinstance(result, dict):
            return result

    except Exception:
        pass

    return {}


def normalize_subject(subject):
    value = str(subject or "").strip()

    value = re.sub(
        r"@carbon\.super$",
        "",
        value,
        flags=re.IGNORECASE,
    )

    value = re.sub(
        r"^PRIMARY/",
        "",
        value,
        flags=re.IGNORECASE,
    )

    return value


def request_token(
    token_url,
    client_key,
    client_secret,
    username,
    password,
    scope,
):
    form = {
        "grant_type": "password",
        "username": username,
        "password": password,
    }

    if scope:
        form["scope"] = scope

    credentials = base64.b64encode(
        (
            f"{client_key}:"
            f"{client_secret}"
        ).encode("utf-8")
    ).decode("ascii")

    request = urllib.request.Request(
        token_url,
        data=urllib.parse.urlencode(
            form
        ).encode("utf-8"),
        headers={
            "Authorization":
                f"Basic {credentials}",
            "Content-Type":
                "application/x-www-form-urlencoded",
            "Accept":
                "application/json",
        },
        method="POST",
    )

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(
            request,
            context=context,
            timeout=20,
        ) as response:
            body = (
                response
                .read()
                .decode("utf-8")
            )

    except urllib.error.HTTPError as error:
        body = (
            error
            .read()
            .decode(
                "utf-8",
                errors="replace",
            )
        )

        try:
            parsed = json.loads(body)

            description = (
                parsed.get(
                    "error_description"
                )
                or parsed.get("description")
                or parsed.get("message")
                or parsed.get("error")
                or f"HTTP {error.code}"
            )

        except Exception:
            description = (
                f"HTTP {error.code}"
            )

        return None, str(description)

    except Exception as error:
        return None, str(error)

    try:
        parsed = json.loads(body)

    except json.JSONDecodeError:
        return (
            None,
            "Token endpoint returned "
            "non-JSON content",
        )

    if not isinstance(parsed, dict):
        return (
            None,
            "Token endpoint returned an "
            "unexpected JSON value",
        )

    return parsed, ""


def subject_from_token_response(response):
    for field in (
        "access_token",
        "accessToken",
        "id_token",
        "idToken",
    ):
        token = response.get(field)

        if (
            not isinstance(token, str)
            or not token
        ):
            continue

        claims = decode_jwt(token)

        subject = normalize_subject(
            claims.get("sub")
        )

        if subject:
            return subject

    return ""


def resolve_subject(
    token_url,
    clients,
    username,
    password,
):
    failures = []

    for _, client_key, client_secret in clients:
        for login in (
            username,
            f"{username}@carbon.super",
        ):
            for scope in (
                None,
                "openid",
            ):
                response, error = request_token(
                    token_url,
                    client_key,
                    client_secret,
                    login,
                    password,
                    scope,
                )

                if response is None:
                    if (
                        error
                        and error not in failures
                    ):
                        failures.append(error)

                    continue

                subject = subject_from_token_response(
                    response
                )

                if not subject:
                    failures.append(
                        "token had no decodable "
                        "sub claim"
                    )
                    continue

                if UUID_PATTERN.fullmatch(
                    subject
                ):
                    return subject

                failures.append(
                    f"unexpected non-UUID "
                    f"subject {subject!r}"
                )

    summary = (
        "; ".join(failures[-5:])
        or "no compatible OAuth client found"
    )

    fail(
        f"Could not resolve JWT subject "
        f"for {username}: {summary}"
    )


def parse_state():
    raw_state = sys.stdin.read()

    try:
        return json.loads(raw_state)

    except Exception:
        first_object = raw_state.find("{")
        last_object = raw_state.rfind("}")

        if (
            first_object < 0
            or last_object < first_object
        ):
            fail(
                "OAuth state input did not "
                "contain a JSON object."
            )

        try:
            return json.loads(
                raw_state[
                    first_object:
                    last_object + 1
                ]
            )

        except Exception as error:
            fail(
                f"Could not parse OAuth state: "
                f"{error}"
            )


def main():
    if len(sys.argv) < 3:
        fail(
            "Usage: "
            "resolve-oauth-persona-subjects.py "
            "<token-url> "
            "<source-file> [source-file ...]"
        )

    token_url = sys.argv[1]

    source_paths = [
        Path(value)
        for value in sys.argv[2:]
    ]

    missing = [
        str(path)
        for path in source_paths
        if not path.exists()
    ]

    if missing:
        fail(
            "Source file does not exist: "
            + ", ".join(missing)
        )

    source = "\n".join(
        path.read_text(
            encoding="utf-8"
        )
        for path in source_paths
    )

    state = parse_state()
    clients = collect_oauth_clients(state)

    if not clients:
        fail(
            "No OAuth client credentials "
            "were found in generated state."
        )

    result = {}

    for username in USERNAMES:
        password = find_password(
            state,
            source,
            username,
        )

        result[username] = resolve_subject(
            token_url,
            clients,
            username,
            password,
        )

    print(
        json.dumps(
            result,
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
PY

chmod +x "$RESOLVER"

###############################################################################
# Replace only the failing SCIM lookup block in the existing generator.
# Preserve the already-generated MI sequence and Compose logic.
###############################################################################

python3 - "$GENERATOR" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start_marker = "lookup_user_id() {"
end_marker = (
    'admin_id="$(lookup_user_id telco.admin)"'
)

start = text.find(start_marker)
end = text.find(
    end_marker,
    start,
)

replacement = r'''log "Resolving the exact JWT subject emitted by APIM for each persona."

subject_map_json="$(
  bash scripts/read-oauth-business-state.sh |
    python3 \
      scripts/resolve-oauth-persona-subjects.py \
      "${APIM_URL}/oauth2/token" \
      services/apim-bootstrapper/src/oauth-business-controls-setup.js \
      scripts/verify-oauth-consent-risk-controls.sh
)"

for username in \
  partner.alpha \
  partner.beta \
  telco.operations \
  telco.product \
  telco.admin
do
  subject_id="$(
    jq -r \
      --arg username "${username}" \
      '.[$username] // empty' \
      <<<"${subject_map_json}"
  )"

  [[ "${subject_id}" =~ ^[0-9a-fA-F-]{36}$ ]] ||
    fail \
      "Token-derived JWT subject is invalid for ${username}."
done

partner_alpha_id="$(
  jq -r \
    '.["partner.alpha"]' \
    <<<"${subject_map_json}"
)"

partner_beta_id="$(
  jq -r \
    '.["partner.beta"]' \
    <<<"${subject_map_json}"
)"

operations_id="$(
  jq -r \
    '.["telco.operations"]' \
    <<<"${subject_map_json}"
)"

product_id="$(
  jq -r \
    '.["telco.product"]' \
    <<<"${subject_map_json}"
)"

admin_id="$(
  jq -r \
    '.["telco.admin"]' \
    <<<"${subject_map_json}"
)"'''

if start < 0:
    if (
        "resolve-oauth-persona-subjects.py"
        in text
    ):
        print(
            "[oauth-persona-subject-fix] "
            "Token-derived subject resolution "
            "is already installed."
        )

        raise SystemExit(0)

    raise SystemExit(
        "[oauth-persona-subject-fix][FAIL] "
        "Could not locate lookup_user_id() "
        "in the generator."
    )

if end < 0:
    raise SystemExit(
        "[oauth-persona-subject-fix][FAIL] "
        "Could not locate the final SCIM "
        "user-ID assignment."
    )

end += len(end_marker)

updated = (
    text[:start]
    + replacement
    + text[end:]
)

path.write_text(
    updated,
    encoding="utf-8",
)

print(
    "[oauth-persona-subject-fix] "
    "Replaced SCIM lookup with "
    "token-derived JWT subject resolution."
)
PY

chmod +x "$GENERATOR"

bash -n "$GENERATOR"
python3 -m py_compile "$RESOLVER"

if grep -Fq \
  '/scim2/Users' \
  "$GENERATOR"
then
  fail \
    "The obsolete SCIM lookup remains in $GENERATOR"
fi

grep -Fq \
  'resolve-oauth-persona-subjects.py' \
  "$GENERATOR" ||
  fail \
    "Token-derived subject resolution was not installed."

###############################################################################
# Keep the migration installer consistent. Rerunning it must not restore the
# obsolete SCIM implementation.
###############################################################################

if [[ -f "$INSTALLER" ]]; then
  python3 - \
    "$INSTALLER" \
    "$GENERATOR" \
    "$RESOLVER" <<'PY'
from pathlib import Path
import sys

installer_path = Path(sys.argv[1])
generator_path = Path(sys.argv[2])
resolver_path = Path(sys.argv[3])

installer = installer_path.read_text(
    encoding="utf-8"
)

generator = generator_path.read_text(
    encoding="utf-8"
).rstrip()

resolver = resolver_path.read_text(
    encoding="utf-8"
).rstrip()

generator_marker = (
    "cat > "
    "scripts/generate-oauth-persona-sequence.sh "
    "<<'PERSONA_GENERATOR'\n"
)

generator_end_marker = (
    "\nPERSONA_GENERATOR\n"
)

start = installer.find(generator_marker)

if start < 0:
    raise SystemExit(
        "[oauth-persona-subject-fix][FAIL] "
        "Could not locate the generator heredoc "
        "inside the final installer."
    )

content_start = (
    start + len(generator_marker)
)

end = installer.find(
    generator_end_marker,
    content_start,
)

if end < 0:
    raise SystemExit(
        "[oauth-persona-subject-fix][FAIL] "
        "Could not locate the generator "
        "heredoc ending."
    )

installer = (
    installer[:content_start]
    + generator
    + installer[end:]
)

resolver_marker = (
    "cat > "
    "scripts/resolve-oauth-persona-subjects.py "
    "<<'PERSONA_SUBJECT_RESOLVER'\n"
)

resolver_end_marker = (
    "\nPERSONA_SUBJECT_RESOLVER\n"
)

if resolver_marker in installer:
    resolver_start = installer.find(
        resolver_marker
    )

    resolver_content_start = (
        resolver_start
        + len(resolver_marker)
    )

    resolver_end = installer.find(
        resolver_end_marker,
        resolver_content_start,
    )

    if resolver_end < 0:
        raise SystemExit(
            "[oauth-persona-subject-fix][FAIL] "
            "Could not locate the resolver "
            "heredoc ending."
        )

    installer = (
        installer[:resolver_content_start]
        + resolver
        + installer[resolver_end:]
    )

else:
    generator_start = installer.find(
        generator_marker
    )

    resolver_block = (
        resolver_marker
        + resolver
        + resolver_end_marker
        + "\n"
    )

    installer = (
        installer[:generator_start]
        + resolver_block
        + installer[generator_start:]
    )

installer_path.write_text(
    installer,
    encoding="utf-8",
)

print(
    "[oauth-persona-subject-fix] "
    "Updated the final installer template."
)
PY

  bash -n "$INSTALLER"
fi

log "Static validation passed."

if [[ "${PATCH_ONLY:-0}" == "1" ]]; then
  log \
    "PATCH_ONLY=1; runtime reconciliation was skipped."

  exit 0
fi

###############################################################################
# The current state already contains newly generated OAuth clients.
# Resolve subjects and deploy MI before running the complete flow again.
###############################################################################

log \
  "Resolving subjects and deploying the generated MI persona registry."

bash "$GENERATOR"

log \
  "Running one complete reconciliation and verification cycle."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[oauth-persona-subject-fix] Complete flow passed.

Backups:
  ${backup_dir}

The MI persona registry now uses the exact subject UUID emitted by APIM.
It no longer depends on /scim2/Users.

EOF

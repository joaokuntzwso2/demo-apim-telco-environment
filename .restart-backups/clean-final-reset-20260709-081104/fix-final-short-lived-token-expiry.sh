#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

OAUTH_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
INSTALLER="install-final-oauth-runtime-logic.sh"
COMPOSE_CONTEXT="scripts/oauth-compose-context.sh"

log() {
  printf '[short-lived-expiry-fix] %s\n' "$*"
}

fail() {
  printf '[short-lived-expiry-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$OAUTH_JS" \
  "$COMPOSE_CONTEXT" \
  scripts/complete-oauth-post-start.sh
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/short-lived-expiry-${timestamp}"

mkdir -p "$backup_dir"

cp "$OAUTH_JS" \
  "$backup_dir/oauth-business-controls-setup.js"

if [[ -f "$INSTALLER" ]]; then
  cp "$INSTALLER" \
    "$backup_dir/install-final-oauth-runtime-logic.sh"
fi

log "Backups written under $backup_dir"

python3 - "$OAUTH_JS" "$INSTALLER" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
installer_path = Path(sys.argv[2])

plain_object_pattern = re.compile(
    r"""
    additionalProperties
    \s*:\s*
    (?!JSON\.stringify\s*\()
    (?P<object>
      \{
        (?=
          [^{}]*
          applicationAccessTokenExpiryTime
          \s*:\s*2
        )
        (?=
          [^{}]*
          userAccessTokenExpiryTime
          \s*:\s*2
        )
        [^{}]*
      \}
    )
    """,
    re.VERBOSE | re.DOTALL,
)

stringified_pattern = re.compile(
    r"""
    additionalProperties
    \s*:\s*
    JSON\.stringify
    \s*\(
      \{
        (?=
          [^{}]*
          applicationAccessTokenExpiryTime
          \s*:\s*2
        )
        (?=
          [^{}]*
          userAccessTokenExpiryTime
          \s*:\s*2
        )
        [^{}]*
      \}
    \s*\)
    """,
    re.VERBOSE | re.DOTALL,
)


def patch_file(path: Path, required: bool) -> None:
    if not path.exists():
        if required:
            raise SystemExit(
                f"[short-lived-expiry-fix][FAIL] "
                f"Missing required file: {path}"
            )

        return

    text = path.read_text(encoding="utf-8")

    already_correct = list(
        stringified_pattern.finditer(text)
    )

    replacements = 0

    def replace(match: re.Match) -> str:
        nonlocal replacements

        replacements += 1

        return (
            "additionalProperties: JSON.stringify("
            + match.group("object")
            + ")"
        )

    updated = plain_object_pattern.sub(
        replace,
        text,
    )

    if replacements == 0 and not already_correct:
        print(
            f"[short-lived-expiry-fix][FAIL] "
            f"Could not find the short-lived "
            f"additionalProperties payload in {path}.",
            file=sys.stderr,
        )

        for number, line in enumerate(
            text.splitlines(),
            start=1,
        ):
            if (
                "applicationAccessTokenExpiryTime" in line
                or "userAccessTokenExpiryTime" in line
                or "additionalProperties" in line
            ):
                print(
                    f"{number}: {line}",
                    file=sys.stderr,
                )

        raise SystemExit(1)

    path.write_text(
        updated,
        encoding="utf-8",
    )

    final_text = path.read_text(
        encoding="utf-8",
    )

    matches = list(
        stringified_pattern.finditer(
            final_text
        )
    )

    if not matches:
        raise SystemExit(
            f"[short-lived-expiry-fix][FAIL] "
            f"JSON-stringified expiry configuration "
            f"was not found in {path}."
        )

    if plain_object_pattern.search(final_text):
        raise SystemExit(
            f"[short-lived-expiry-fix][FAIL] "
            f"A non-stringified short-lived expiry "
            f"configuration remains in {path}."
        )

    if replacements:
        print(
            f"[short-lived-expiry-fix] "
            f"Corrected {replacements} payload(s) "
            f"in {path}."
        )
    else:
        print(
            f"[short-lived-expiry-fix] "
            f"{path} is already correct."
        )


patch_file(
    source_path,
    required=True,
)

patch_file(
    installer_path,
    required=False,
)
PY

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_JS"
fi

python3 - "$OAUTH_JS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

pattern = re.compile(
    r"""
    additionalProperties
    \s*:\s*
    JSON\.stringify
    \s*\(
      \{
        (?=
          [^{}]*
          applicationAccessTokenExpiryTime
          \s*:\s*2
        )
        (?=
          [^{}]*
          userAccessTokenExpiryTime
          \s*:\s*2
        )
        [^{}]*
      \}
    \s*\)
    """,
    re.VERBOSE | re.DOTALL,
)

matches = list(pattern.finditer(text))

if len(matches) != 1:
    raise SystemExit(
        "[short-lived-expiry-fix][FAIL] "
        "Expected exactly one correctly configured "
        f"short-lived key payload; found {len(matches)}."
    )

print(
    "[short-lived-expiry-fix] "
    "Short-lived key payload validation passed."
)
PY

echo
echo "[short-lived-expiry-fix] Corrected configuration:"

grep -n \
  -A 8 \
  -B 5 \
  'applicationAccessTokenExpiryTime' \
  "$OAUTH_JS"

echo

if [[ -f "$INSTALLER" ]]; then
  bash -n "$INSTALLER"
fi

bash -n scripts/complete-oauth-post-start.sh

source "$COMPOSE_CONTEXT"
resolve_oauth_compose_context "$ROOT"

services="$(
  "${OAUTH_COMPOSE[@]}" config --services
)"

grep -Fxq 'apim-bootstrapper' <<<"$services" ||
  fail "apim-bootstrapper is absent from the Compose topology."

log "Building only apim-bootstrapper with the corrected OAuth key payload."

"${OAUTH_COMPOSE[@]}" build apim-bootstrapper

log "Running one reconciliation and verification cycle."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[short-lived-expiry-fix] Complete verification passed.

Backups:
  ${backup_dir}

The short-lived OAuth key is now created with:

  additionalProperties: JSON.stringify({
    applicationAccessTokenExpiryTime: 2,
    userAccessTokenExpiryTime: 2
  })

EOF

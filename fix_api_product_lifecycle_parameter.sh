#!/usr/bin/env bash
set -euo pipefail

SOURCE="services/apim-bootstrapper/src/developer-experience-setup.js"
INSTALLER="implement_telco_developer_experience.sh"

if [[ ! -f "$SOURCE" ]]; then
  echo "[api-product-lifecycle-fix] ERROR: run from the repository root; missing $SOURCE" >&2
  exit 1
fi

backup_once() {
  local file="$1"
  local backup="${file}.before-api-product-lifecycle-fix"
  if [[ -f "$file" && ! -f "$backup" ]]; then
    cp "$file" "$backup"
  fi
}

backup_once "$SOURCE"
[[ -f "$INSTALLER" ]] && backup_once "$INSTALLER"

python3 <<'PY'
from pathlib import Path

files = [Path("services/apim-bootstrapper/src/developer-experience-setup.js")]
installer = Path("implement_telco_developer_experience.sh")
if installer.exists():
    files.append(installer)

old_lifecycle = (
    "/api/am/publisher/v4/api-products/change-lifecycle?"
    "apiId=${encodeURIComponent("
)
new_lifecycle = (
    "/api/am/publisher/v4/api-products/change-lifecycle?"
    "apiProductId=${encodeURIComponent("
)

old_reader = """async function readApiDefinition(token, apiId) {
  try {
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${apiId}/swagger`,
      {
        bearer: token,
        headers: {
          Accept: 'application/json, application/yaml, text/yaml, */*'
        },
        returnResponse: true
      }
    );
    return parseDefinition(response.data || response.text);
  } catch (error) {
    log(`OpenAPI/AsyncAPI definition could not be read for ${apiId}: ${error.message}`);
    return null;
  }
}
"""

new_reader = """async function readApiDefinition(token, api) {
  const apiId = api.id;
  const apiType = String(api.type || 'HTTP').toUpperCase();
  const asyncApiTypes = new Set([
    'WS',
    'WEBSUB',
    'SSE',
    'WEBHOOK',
    'ASYNC'
  ]);

  const definitionResource =
    apiType === 'GRAPHQL'
      ? 'graphql-schema'
      : asyncApiTypes.has(apiType)
        ? 'asyncapi'
        : 'swagger';

  try {
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${apiId}/${definitionResource}`,
      {
        bearer: token,
        headers: {
          Accept: 'application/json, application/yaml, text/yaml, */*'
        },
        returnResponse: true
      }
    );
    return parseDefinition(response.data || response.text);
  } catch (error) {
    log(
      `${apiType} definition could not be read for ${api.name || apiId} ` +
      `from ${definitionResource}: ${error.message}`
    );
    return null;
  }
}
"""

old_reader_call = "const definition = await readApiDefinition(token, api.id);"
new_reader_call = "const definition = await readApiDefinition(token, api);"

for path in files:
    text = path.read_text()

    lifecycle_count = text.count(old_lifecycle)
    if lifecycle_count:
        text = text.replace(old_lifecycle, new_lifecycle)
        print(
            f"[api-product-lifecycle-fix] corrected {lifecycle_count} "
            f"lifecycle parameter occurrence(s) in {path}"
        )
    elif "change-lifecycle?apiProductId=${encodeURIComponent(" not in text:
        raise SystemExit(
            f"[api-product-lifecycle-fix] lifecycle URL pattern not found in {path}"
        )

    if old_reader in text:
        text = text.replace(old_reader, new_reader, 1)
        print(f"[api-product-lifecycle-fix] made API definition lookup type-aware in {path}")
    elif "const asyncApiTypes = new Set([" not in text:
        # The installer contains the JavaScript source in a heredoc. If its
        # formatting was changed, do not silently leave the original bug there.
        if path.name == "implement_telco_developer_experience.sh":
            print(
                "[api-product-lifecycle-fix] WARNING: definition-reader block "
                "not found in installer; lifecycle parameter was still fixed."
            )
        else:
            raise SystemExit(
                f"[api-product-lifecycle-fix] definition reader pattern not found in {path}"
            )

    if old_reader_call in text:
        text = text.replace(old_reader_call, new_reader_call, 1)
    elif new_reader_call not in text and path.name != "implement_telco_developer_experience.sh":
        raise SystemExit(
            f"[api-product-lifecycle-fix] definition reader call not found in {path}"
        )

    path.write_text(text)

source = Path("services/apim-bootstrapper/src/developer-experience-setup.js")
updated = source.read_text()

required_fragments = [
    "change-lifecycle?apiProductId=${encodeURIComponent(",
    "const definition = await readApiDefinition(token, api);",
    "const asyncApiTypes = new Set([",
]

for fragment in required_fragments:
    if fragment not in updated:
        raise SystemExit(
            f"[api-product-lifecycle-fix] required result missing: {fragment}"
        )
PY

node --check "$SOURCE"
[[ -f "$INSTALLER" ]] && bash -n "$INSTALLER"

echo
echo "[api-product-lifecycle-fix] PASS: source is patched and syntactically valid."
echo
echo "[api-product-lifecycle-fix] Rebuild and rerun only the one-shot bootstrapper:"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml rm -sf apim-bootstrapper"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml build --no-cache apim-bootstrapper"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml up -d --force-recreate apim-bootstrapper"
echo "  docker logs -f telco-apim-bootstrapper"

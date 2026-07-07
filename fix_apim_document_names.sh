#!/usr/bin/env bash
set -euo pipefail

SOURCE="services/apim-bootstrapper/src/developer-experience-setup.js"
VERIFIER="scripts/verify-developer-experience.sh"
INSTALLER="implement_telco_developer_experience.sh"

for required in "$SOURCE" "$VERIFIER"; do
  if [[ ! -f "$required" ]]; then
    echo "[document-name-fix] ERROR: run from the repository root; missing $required" >&2
    exit 1
  fi
done

backup_once() {
  local file="$1"
  local backup="${file}.before-document-name-fix"
  if [[ -f "$file" && ! -f "$backup" ]]; then
    cp "$file" "$backup"
  fi
}

backup_once "$SOURCE"
backup_once "$VERIFIER"
[[ -f "$INSTALLER" ]] && backup_once "$INSTALLER"

python3 <<'PY'
from pathlib import Path

replacements = {
    "07 - SLA, Support and Resilience":
        "07 - SLA Support and Resilience",
    "08 - Code Samples, Postman and SDKs":
        "08 - Code Samples Postman and SDKs",
    "04 - Commercial Plans, Rate Limits and SLA":
        "04 - Commercial Plans Rate Limits and SLA",
    "05 - Sandbox, Postman and SDK Toolkit":
        "05 - Sandbox Postman and SDK Toolkit",
}

files = [
    Path("services/apim-bootstrapper/src/developer-experience-setup.js"),
    Path("scripts/verify-developer-experience.sh"),
]

installer = Path("implement_telco_developer_experience.sh")
if installer.exists():
    files.append(installer)

for path in files:
    text = path.read_text()
    for old, new in replacements.items():
        text = text.replace(old, new)
    path.write_text(text)
    print(f"[document-name-fix] updated names in {path}")

source = Path("services/apim-bootstrapper/src/developer-experience-setup.js")
text = source.read_text()

sanitizer = (
    "\nfunction normalizeDocumentName(value) {\n"
    "  // APIM document names are backed by registry resources and reject several\n"
    "  // punctuation characters. Keep generated names stable and API-safe.\n"
    "  return String(value || '')\n"
    "    .replace(/[~!@#;%^*()+={}|<>\\\"',]/g, '')\n"
    "    .replace(/\\s+/g, ' ')\n"
    "    .trim();\n"
    "}\n\n"
)

if "function normalizeDocumentName(value)" not in text:
    anchor = "async function upsertDocument(token, basePath, document) {"
    if anchor not in text:
        raise SystemExit(
            "[document-name-fix] Could not find upsertDocument() in the bootstrap source."
        )
    text = text.replace(anchor, sanitizer + anchor, 1)

old_start = (
    "async function upsertDocument(token, basePath, document) {\n"
    "  const existing = await listDocuments(token, basePath);\n"
    "  let current = existing.find(item => item.name === document.name);\n\n"
    "  const metadata = {\n"
    "    name: document.name,"
)

new_start = (
    "async function upsertDocument(token, basePath, document) {\n"
    "  const documentName = normalizeDocumentName(document.name);\n"
    "  if (!documentName) {\n"
    "    throw new Error(`Document name became empty after normalization: ${document.name}`);\n"
    "  }\n\n"
    "  const existing = await listDocuments(token, basePath);\n"
    "  let current = existing.find(item => item.name === documentName);\n\n"
    "  const metadata = {\n"
    "    name: documentName,"
)

if old_start in text:
    text = text.replace(old_start, new_start, 1)
elif "const documentName = normalizeDocumentName(document.name);" not in text:
    raise SystemExit(
        "[document-name-fix] Could not patch the start of upsertDocument()."
    )

text = text.replace(
    "`Document metadata did not return an ID for ${document.name}`",
    "`Document metadata did not return an ID for ${documentName}`",
)
text = text.replace(
    "log(`upserted document: ${document.name}`);",
    "log(`upserted document: ${documentName}`);",
)

source.write_text(text)
print("[document-name-fix] added defensive APIM document-name normalization")
PY

node --check "$SOURCE"
bash -n "$VERIFIER"
[[ -f "$INSTALLER" ]] && bash -n "$INSTALLER"

echo
echo "[document-name-fix] PASS: source and verification scripts are syntactically valid."
echo
echo "[document-name-fix] Rebuild and rerun only the one-shot bootstrapper:"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml rm -sf apim-bootstrapper"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml build --no-cache apim-bootstrapper"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml up -d --force-recreate apim-bootstrapper"
echo "  docker logs -f telco-apim-bootstrapper"

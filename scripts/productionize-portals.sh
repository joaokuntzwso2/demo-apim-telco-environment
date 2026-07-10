#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/productionize-portals.sh --audit
  ./scripts/productionize-portals.sh --apply
  ./scripts/productionize-portals.sh --apply --rebuild
  ./scripts/productionize-portals.sh --restore latest
  ./scripts/productionize-portals.sh --restore PATH --rebuild
EOF
}

ACTION="audit"
REBUILD="false"
RESTORE_FROM=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit)
      ACTION="audit"
      ;;
    --apply)
      ACTION="apply"
      ;;
    --rebuild)
      REBUILD="true"
      ;;
    --restore)
      ACTION="restore"
      shift
      [ "$#" -gt 0 ] || {
        echo "--restore requires 'latest' or a backup path" >&2
        exit 2
      }
      RESTORE_FROM="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

[ -n "$ROOT" ] || {
  echo "Run this script from inside the Git repository." >&2
  exit 1
}

cd "$ROOT"

MAIN_PORTAL="services/demo-portal"
PIPELINE_PORTAL="services/pipeline-portal"
CATALOG="artifacts/catalog.json"

BACKUP_ROOT=".portal-production-backups"
AUDIT_ROOT=".portal-production-audit"
STAMP="$(date +%Y%m%d-%H%M%S)"

require_path() {
  [ -e "$1" ] || {
    echo "Required path not found: $1" >&2
    exit 1
  }
}

require_path "$MAIN_PORTAL"
require_path "$PIPELINE_PORTAL"

scan_visible_terms() {
  out="$1"
  : > "$out"

  find "$MAIN_PORTAL" "$PIPELINE_PORTAL" \
    -type f \
    \( \
      -name '*.html' \
      -o -name '*.js' \
      -o -name '*.json' \
      -o -name '*.css' \
    \) \
    -not -path '*/node_modules/*' \
    -not -name 'package-lock.json' \
    -print0 |
  while IFS= read -r -d '' file; do
    grep -nEi \
      '\b(demo|mock|mocked|simulation|simulate|presenter|fake)\b' \
      "$file" 2>/dev/null |
      sed "s#^#$file:#" >> "$out" || true
  done

  if [ -f "$CATALOG" ]; then
    grep -nEi \
      '\b(demo|mock|mocked|simulation|simulate|presenter|fake|intentionally|negative pipeline scenario)\b' \
      "$CATALOG" 2>/dev/null |
      sed "s#^#$CATALOG:#" >> "$out" || true
  fi
}

validate_sources() {
  echo "Validating modified portal sources..."

  if command -v node >/dev/null 2>&1; then
    find "$MAIN_PORTAL" "$PIPELINE_PORTAL" \
      -type f \
      -name '*.js' \
      -not -path '*/node_modules/*' \
      -print0 |
    while IFS= read -r -d '' file; do
      node --check "$file" >/dev/null
    done

    echo "JavaScript syntax: OK"
  else
    echo "WARN: node is not installed; JavaScript validation skipped."
  fi

  python3 - <<'PY'
import json
from pathlib import Path

files = (
    Path("services/demo-portal/package.json"),
    Path("services/pipeline-portal/package.json"),
    Path("artifacts/catalog.json"),
)

for path in files:
    if not path.exists():
        continue

    json.loads(path.read_text(encoding="utf-8"))
    print(f"JSON OK: {path}")
PY

  git diff --check
  echo "Git whitespace validation: OK"
}

rebuild_portals() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "WARN: Docker is not installed; rebuild skipped."
    return 0
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "WARN: docker compose is unavailable; rebuild skipped."
    return 0
  fi

  services="$(docker compose config --services 2>/dev/null || true)"
  selected=""

  for candidate in \
    demo-portal \
    pipeline-portal \
    telco-demo-portal \
    telco-pipeline-portal
  do
    if printf '%s\n' "$services" | grep -qx "$candidate"; then
      selected="$selected $candidate"
    fi
  done

  if [ -z "${selected# }" ]; then
    echo "WARN: portal services were not found in the default Compose topology."
    echo "Available services:"
    printf '%s\n' "$services"
    return 0
  fi

  echo "Rebuilding:$selected"

  # Service names contain no spaces. Intentional shell expansion.
  # shellcheck disable=SC2086
  docker compose up -d --build $selected
}

if [ "$ACTION" = "audit" ]; then
  audit_dir="$AUDIT_ROOT/$STAMP"
  mkdir -p "$audit_dir"

  scan_visible_terms "$audit_dir/visible-language.txt"

  {
    echo "Portal production-language audit"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Customer-visible terms requiring review:"

    if [ -s "$audit_dir/visible-language.txt" ]; then
      cat "$audit_dir/visible-language.txt"
    else
      echo "None found."
    fi
  } > "$audit_dir/report.txt"

  cat "$audit_dir/report.txt"

  echo
  echo "No files changed. Apply with:"
  echo "  ./scripts/productionize-portals.sh --apply --rebuild"

  exit 0
fi

if [ "$ACTION" = "restore" ]; then
  if [ "$RESTORE_FROM" = "latest" ]; then
    [ -f "$BACKUP_ROOT/LATEST" ] || {
      echo "No latest backup marker exists." >&2
      exit 1
    }

    RESTORE_FROM="$(cat "$BACKUP_ROOT/LATEST")"
  fi

  [ -f "$RESTORE_FROM/portal-sources.tar.gz" ] || {
    echo "Backup archive not found:" >&2
    echo "  $RESTORE_FROM/portal-sources.tar.gz" >&2
    exit 1
  }

  rm -f \
    "$MAIN_PORTAL/public/operations-workspace.html" \
    "$MAIN_PORTAL/public/operations-workspace.js"

  tar -xzf \
    "$RESTORE_FROM/portal-sources.tar.gz" \
    -C "$ROOT"

  echo "Restored portal sources from: $RESTORE_FROM"

  validate_sources

  if [ "$REBUILD" = "true" ]; then
    rebuild_portals
  fi

  exit 0
fi

backup_dir="$BACKUP_ROOT/$STAMP"
mkdir -p "$backup_dir"

targets="$MAIN_PORTAL $PIPELINE_PORTAL"

if [ -f "$CATALOG" ]; then
  targets="$targets $CATALOG"
fi

# Paths contain no spaces. Intentional shell expansion.
# shellcheck disable=SC2086
tar -czf "$backup_dir/portal-sources.tar.gz" $targets

git status --short > "$backup_dir/git-status-before.txt"
git diff > "$backup_dir/working-tree-before.patch"
git diff --cached > "$backup_dir/index-before.patch"

printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/LATEST"

echo "Backup created: $backup_dir"

python3 - <<'PY'
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(".")
MAIN = ROOT / "services/demo-portal"
PIPELINE = ROOT / "services/pipeline-portal"
CATALOG = ROOT / "artifacts/catalog.json"

TEXT_SUFFIXES = {
    ".html",
    ".js",
    ".json",
    ".css",
}

EXACT_REPLACEMENTS = [
    (
        "window.DEMO_CONFIG",
        "window.PORTAL_CONFIG",
    ),
    (
        "Telco demo portal running",
        "Telco API business portal running",
    ),
    (
        "telco-demo-portal",
        "telco-api-business-portal",
    ),
    (
        "telco-pipeline-portal",
        "telco-api-delivery-portal",
    ),
    (
        "Demo architecture",
        "Platform architecture",
    ),
    (
        "12-country telco API commercialization demo",
        "Regional telco API commercialization platform",
    ),
    (
        (
            "This portal simulates the executive view a group API office "
            "would use to track multi-country APIs, partner products, "
            "monetization, and runtime network events."
        ),
        (
            "This portal provides the group API office with an executive "
            "view of multi-country APIs, partner products, monetization, "
            "and runtime network events."
        ),
    ),
    (
        "Moesif-style usage view",
        "API consumption analytics",
    ),
    (
        "Demo capability map",
        "Platform capability map",
    ),
    (
        "From gateway demo to API business platform",
        "From API gateway to API business platform",
    ),
    (
        (
            "Use this screen to set the narrative: the customer is not "
            "buying only a gateway. They are buying the foundation for "
            "API productization across countries, partners and network "
            "capabilities."
        ),
        (
            "The platform provides a foundation for API productization "
            "across operating companies, partners and network capabilities, "
            "extending beyond gateway traffic management."
        ),
    ),
    (
        (
            "Demonstrates legacy BSS exposure under the same governance "
            "and API product strategy."
        ),
        (
            "Legacy BSS services are exposed under the same governance, "
            "security and API product strategy."
        ),
    ),
    (
        "Event-native broker simulation",
        "Event-native broker services",
    ),
    (
        (
            "Kafka-style topic catalog for network, fraud and settlement "
            "events. This shows how the telco monetizes real-time event "
            "delivery in addition to REST APIs."
        ),
        (
            "Topic catalog for network, fraud and settlement events, "
            "supporting commercial real-time event delivery alongside "
            "REST APIs."
        ),
    ),
    (
        "Real Kafka event-native demo",
        "Kafka event delivery",
    ),
    (
        "Failover simulation",
        "Runtime resilience",
    ),
    (
        (
            "Simulate a degraded country gateway and show how selected "
            "API traffic can move to another runtime without changing "
            "the central API product model."
        ),
        (
            "Run a controlled resilience test for a country gateway and "
            "validate that selected API traffic can move to another runtime "
            "without changing the central API product model."
        ),
    ),
    (
        "Simulate failover",
        "Run resilience test",
    ),
    (
        "Demo Commander",
        "Operations Workspace",
    ),
    (
        "Presenter control room",
        "Operations control room",
    ),
    (
        (
            "A polished runbook for the full telco API platform demo. "
            "Use it to drive the story,\n  open the right screens, run "
            "live API checks and keep the narrative consistent."
        ),
        (
            "A centralized workspace for platform readiness checks, "
            "operational workflows and direct access to API management "
            "services."
        ),
    ),
    (
        "Demo-ready",
        "Operational",
    ),
    (
        "Demo flow",
        "Operational workflow",
    ),
    (
        "Talk track",
        "Operational guidance",
    ),
    (
        "Live demo checks",
        "Platform readiness checks",
    ),
    (
        "Use this to verify the environment before or during the presentation.",
        "Use this workspace to verify platform dependencies and service readiness.",
    ),
    (
        "Click “Run platform check” to validate the local demo services.",
        "Click “Run platform check” to validate platform services.",
    ),
    (
        'Click "Run platform check" to validate the local demo services.',
        'Click "Run platform check" to validate platform services.',
    ),
    (
        "/demo-commander.html",
        "/operations-workspace.html",
    ),
    (
        "/demo-commander.js",
        "/operations-workspace.js",
    ),
    (
        "demo-commander.html",
        "operations-workspace.html",
    ),
    (
        "demo-commander.js",
        "operations-workspace.js",
    ),
    (
        "Pipeline portal",
        "API delivery portal",
    ),
    (
        "Pipeline Portal",
        "API Delivery Portal",
    ),
    (
        "Open API Pipeline",
        "Open API Delivery Pipeline",
    ),
    (
        "Open APIOps Pipeline",
        "Open API Delivery Pipeline",
    ),
    (
        "Reset backlog",
        "Reset delivery backlog",
    ),
    (
        "Pipeline backlog reset.",
        "Delivery backlog reset.",
    ),
    (
        "API was already processed by the pipeline",
        "API was already processed by the delivery pipeline",
    ),
    (
        "Per demo requirement:",
        "Operational behavior:",
    ),
    (
        "the presenter can rerun",
        "the operator can rerun",
    ),
    (
        (
            "Simulation mode is disabled for this demo flow.\n"
            "Set APIM_MODE=real and start APIM."
        ),
        (
            "Offline import mode is disabled.\n"
            "Set APIM_MODE=real and ensure API Manager is available."
        ),
    ),
    (
        "Simulation mode is disabled for this demo flow.",
        "Offline import mode is disabled.",
    ),
    (
        "Set APIM_MODE=real and start APIM.",
        "Set APIM_MODE=real and ensure API Manager is available.",
    ),
    (
        "for WSO2 APIM 4.7 demo",
        "for WSO2 API Manager 4.7",
    ),
    (
        "for WSO2 API Manager 4.7 demo",
        "for WSO2 API Manager 4.7",
    ),
    (
        "Negative pipeline scenario:",
        "Governance remediation required:",
    ),
    (
        "negative pipeline scenario",
        "governance remediation case",
    ),
    (
        "intentionally misses",
        "is missing",
    ),
    (
        "intentionally omits",
        "is missing",
    ),
    (
        "intentionally invalid",
        "currently non-compliant",
    ),
    (
        "mocked data",
        "service data",
    ),
    (
        "mock data",
        "service data",
    ),
]

REGEX_REPLACEMENTS = [
    (
        re.compile(r"\bpresenter\b", re.IGNORECASE),
        "operator",
    ),
    (
        re.compile(r"\bdemo services\b", re.IGNORECASE),
        "platform services",
    ),
    (
        re.compile(r"\bdemo environment\b", re.IGNORECASE),
        "platform environment",
    ),
    (
        re.compile(r"\bdemo data\b", re.IGNORECASE),
        "service data",
    ),
]


def is_text_file(path: Path) -> bool:
    if "node_modules" in path.parts:
        return False

    if path.name == "package-lock.json":
        return True

    return path.suffix.lower() in TEXT_SUFFIXES


def rewrite_text(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    updated = original

    for old, new in EXACT_REPLACEMENTS:
        updated = updated.replace(old, new)

    for pattern, replacement in REGEX_REPLACEMENTS:
        updated = pattern.sub(replacement, updated)

    if updated == original:
        return False

    path.write_text(updated, encoding="utf-8")
    print(f"updated: {path}")
    return True


for base in (MAIN, PIPELINE):
    for path in sorted(base.rglob("*")):
        if path.is_file() and is_text_file(path):
            rewrite_text(path)


# Rename the presenter-oriented page while retaining its operational features.
public = MAIN / "public"

renames = (
    (
        public / "demo-commander.html",
        public / "operations-workspace.html",
    ),
    (
        public / "demo-commander.js",
        public / "operations-workspace.js",
    ),
)

for source, target in renames:
    if not source.exists():
        continue

    if target.exists():
        target.unlink()

    source.rename(target)
    print(f"renamed: {source} -> {target}")


# Make package metadata customer-neutral without changing Compose service names.
package_updates = {
    MAIN / "package.json": {
        "name": "telco-api-business-portal",
        "description": (
            "Regional telecommunications API business and operations portal."
        ),
    },
    PIPELINE / "package.json": {
        "name": "telco-api-delivery-portal",
        "description": (
            "Governed API delivery and APICTL integration portal "
            "for WSO2 API Manager 4.7."
        ),
    },
}

for path, fields in package_updates.items():
    if not path.exists():
        continue

    data = json.loads(path.read_text(encoding="utf-8"))
    data.update(fields)

    path.write_text(
        json.dumps(
            data,
            indent=2,
            ensure_ascii=False,
        ) + "\n",
        encoding="utf-8",
    )

    print(f"updated metadata: {path}")


# Clean descriptive catalog fields only.
# IDs, paths, protocols and contract references remain unchanged.
if CATALOG.exists():
    catalog = json.loads(
        CATALOG.read_text(encoding="utf-8")
    )

    descriptive_keys = {
        "description",
        "summary",
        "displayName",
        "label",
        "notes",
        "message",
        "purpose",
        "businessDescription",
        "tryoutDescription",
        "title",
    }

    catalog_replacements = [
        (
            "Negative pipeline scenario:",
            "Governance remediation required:",
        ),
        (
            "negative pipeline scenario",
            "governance remediation case",
        ),
        (
            "intentionally misses",
            "is missing",
        ),
        (
            "intentionally omits",
            "is missing",
        ),
        (
            "intentionally invalid",
            "currently non-compliant",
        ),
        (
            "mocked data",
            "service data",
        ),
        (
            "mock data",
            "service data",
        ),
        (
            "demo environment",
            "platform environment",
        ),
        (
            "demo flow",
            "delivery workflow",
        ),
        (
            "demo",
            "platform",
        ),
        (
            "simulation",
            "controlled test",
        ),
        (
            "simulate",
            "run",
        ),
        (
            "presenter",
            "operator",
        ),
    ]

    def clean(value, key=None):
        if isinstance(value, dict):
            return {
                child_key: clean(child_value, child_key)
                for child_key, child_value in value.items()
            }

        if isinstance(value, list):
            return [
                clean(child_value, key)
                for child_value in value
            ]

        if isinstance(value, str) and key in descriptive_keys:
            result = value

            for old, new in catalog_replacements:
                result = re.sub(
                    rf"\b{re.escape(old)}\b",
                    new,
                    result,
                    flags=re.IGNORECASE,
                )

            return result

        return value

    catalog = clean(catalog)

    CATALOG.write_text(
        json.dumps(
            catalog,
            indent=2,
            ensure_ascii=False,
        ) + "\n",
        encoding="utf-8",
    )

    print(
        "updated descriptive catalog fields: "
        f"{CATALOG}"
    )
PY

validate_sources

audit_dir="$AUDIT_ROOT/$STAMP-after"
mkdir -p "$audit_dir"

scan_visible_terms "$audit_dir/visible-language.txt"

if [ -s "$audit_dir/visible-language.txt" ]; then
  echo
  echo "Remaining terms requiring manual review:"
  cat "$audit_dir/visible-language.txt"
  echo
  echo "These may be internal identifiers or wording added by newer local changes."
else
  echo
  echo "No remaining demo/mock/simulation/presenter terms were found."
fi

echo
echo "Review changes with:"
echo "  git diff -- services/demo-portal services/pipeline-portal artifacts/catalog.json"
echo
echo "Rollback with:"
echo "  ./scripts/productionize-portals.sh --restore latest --rebuild"

if [ "$REBUILD" = "true" ]; then
  rebuild_portals
fi

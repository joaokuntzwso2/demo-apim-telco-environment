#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "$ROOT" ]]; then
  echo "Run this script from inside the repository." >&2
  exit 1
fi

cd "$ROOT"

RUNTIME="services/wso2-mi/synapse-configs/default"
PROJECT_ROOT="integration-projects/TelcoIntegrationPlatform"
PROJECT_ARTIFACTS="$PROJECT_ROOT/src/main/wso2mi/artifacts"

for required in \
  "$RUNTIME" \
  "$PROJECT_ROOT/pom.xml" \
  "$PROJECT_ROOT/mvnw" \
  "$PROJECT_ARTIFACTS"
do
  if [[ ! -e "$required" ]]; then
    echo "Required path is missing: $required" >&2
    exit 1
  fi
done

echo
echo "============================================================"
echo "1. Comparing project artifacts with runtime artifacts"
echo "============================================================"

python3 - <<'PY'
from pathlib import Path
import hashlib
import sys

runtime = Path("services/wso2-mi/synapse-configs/default")
project = Path(
    "integration-projects/TelcoIntegrationPlatform/"
    "src/main/wso2mi/artifacts"
)

mappings = (
    ("api", "apis"),
    ("endpoints", "endpoints"),
    ("sequences", "sequences"),
    ("templates", "templates"),
)

failures = []


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    hasher.update(path.read_bytes())
    return hasher.hexdigest()


for runtime_name, project_name in mappings:
    source_dir = runtime / runtime_name
    destination_dir = project / project_name

    if not source_dir.exists():
        print(f"SKIP: runtime directory does not exist: {source_dir}")
        continue

    if not destination_dir.exists():
        failures.append(
            f"Missing project directory: {destination_dir}"
        )
        continue

    source_files = {
        path.name: path
        for path in source_dir.glob("*.xml")
        if path.is_file()
    }

    project_files = {
        path.name: path
        for path in destination_dir.glob("*.xml")
        if path.is_file()
    }

    missing = sorted(set(source_files) - set(project_files))
    extra = sorted(set(project_files) - set(source_files))
    common = sorted(set(source_files) & set(project_files))

    changed = [
        name
        for name in common
        if digest(source_files[name]) != digest(project_files[name])
    ]

    print()
    print(f"{runtime_name} -> {project_name}")
    print(f"  Runtime files: {len(source_files)}")
    print(f"  Project files: {len(project_files)}")

    if missing:
        print("  Missing:")
        for name in missing:
            print(f"    - {name}")
            failures.append(
                f"Missing project artifact: "
                f"{destination_dir / name}"
            )

    if extra:
        print("  Extra:")
        for name in extra:
            print(f"    - {name}")
            failures.append(
                f"Unexpected project artifact: "
                f"{destination_dir / name}"
            )

    if changed:
        print("  Content differs:")
        for name in changed:
            print(f"    - {name}")
            failures.append(
                f"Artifact is not byte-identical: {name}"
            )

    if not missing and not extra and not changed:
        print("  PASS: all artifacts are byte-identical")


if failures:
    print()
    print("MI project integrity validation FAILED:", file=sys.stderr)

    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)

    sys.exit(1)

print()
print("PASS: the MI visual project exactly mirrors the runtime XML.")
PY

echo
echo "============================================================"
echo "2. Validating XML"
echo "============================================================"

if command -v xmllint >/dev/null 2>&1; then
  while IFS= read -r -d '' file; do
    xmllint --noout "$file"
  done < <(
    find "$PROJECT_ARTIFACTS" \
      -type f \
      -name '*.xml' \
      -print0
  )

  echo "PASS: all project XML files are well formed."
else
  echo "WARN: xmllint is unavailable; XML validation skipped."
fi

echo
echo "============================================================"
echo "3. Checking Java and Maven wrapper"
echo "============================================================"

java -version

chmod +x "$PROJECT_ROOT/mvnw"

echo
echo "============================================================"
echo "4. Building MI project from scratch"
echo "============================================================"

(
  cd "$PROJECT_ROOT"
  ./mvnw clean package
)

echo
echo "============================================================"
echo "5. Locating generated deployment artifacts"
echo "============================================================"

CAR_FILES="$(
  find "$PROJECT_ROOT/target" \
    -type f \
    -name '*.car' \
    -print 2>/dev/null || true
)"

if [[ -z "$CAR_FILES" ]]; then
  echo "No Carbon Application was found under:" >&2
  echo "  $PROJECT_ROOT/target" >&2
  echo >&2
  echo "Inspect the Maven output and pom.xml packaging configuration." >&2
  exit 1
fi

printf '%s\n' "$CAR_FILES"

echo
echo "============================================================"
echo "MI visual project validation passed"
echo "============================================================"

echo
echo "The following checks succeeded:"
echo "  - Runtime and project XML are byte-identical"
echo "  - XML files are well formed"
echo "  - Maven project builds successfully"
echo "  - Carbon Application was generated"

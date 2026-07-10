#!/usr/bin/env bash
set -Eeuo pipefail

# Repository cleanup and security hygiene for demo-apim-telco-environment.
#
# Default: read-only audit.
# Full safe cleanup:
#   ./scripts/cleanup-repository.sh --apply-all
#
# What --apply-all does:
#   1. Creates local recovery artifacts under .repo-cleanup-backups/.
#   2. Hardens .gitignore.
#   3. Removes known generated/transient paths.
#   4. Removes generated validation logs that were accidentally committed.
#   5. Untracks local secret/runtime-state files while preserving local copies.
#   6. Deletes unreferenced, unmodified one-time fix/install/patch scripts.
#   7. Deletes unreferenced, unmodified legacy lifecycle wrappers.
#   8. Runs shell, Git whitespace, Compose, duplicate-file, and secret checks.
#   9. Runs gitleaks when installed.
#
# Deliberate safety limits:
#   - Never deletes a migration/lifecycle script referenced by another tracked file.
#   - Never deletes a locally modified tracked script.
#   - Never removes duplicate contracts automatically.
#   - Never rewrites Git history.
#   - Never deletes local .env, key, certificate, credential, or token files.

APPLY=false
REMOVE_TRACKED_GENERATED=false
UNTRACK_SENSITIVE=false
PRUNE_MIGRATIONS=false
PRUNE_LEGACY=false
HISTORY_SCAN=false
CHECK_COMPOSE=true
REPORT_ROOT=".repo-audit"
BACKUP_ROOT=".repo-cleanup-backups"

usage() {
  cat <<'EOF'
Usage: cleanup-repository.sh [options]

Safe modes:
  (no options)                Read-only audit; changes nothing.
  --apply-all                 Apply every safe cleanup action.

Granular modes:
  --apply                     Apply .gitignore updates and remove untracked
                              generated/transient output.
  --remove-tracked-generated  With --apply, git-rm known generated validation
                              and backup directories accidentally committed.
  --untrack-sensitive         With --apply, git-rm --cached obvious local
                              secret/runtime-state paths, preserving local files.
  --prune-migrations          With --apply, remove unreferenced and unmodified
                              one-time fix/install/patch/repair/implement scripts.
  --prune-legacy              With --apply, remove unreferenced and unmodified
                              old start/stop/reset lifecycle wrappers.
  --history-scan              Run gitleaks against Git history when installed.
  --no-compose-check          Skip Docker Compose validation.
  --report-root PATH          Audit report location (default: .repo-audit).
  --backup-root PATH          Local recovery location
                              (default: .repo-cleanup-backups).
  -h, --help                  Show this help.

Recommended:
  ./scripts/cleanup-repository.sh
  ./scripts/cleanup-repository.sh --apply-all
  git diff --stat
  git diff
  git status --short
EOF
}

while (($#)); do
  case "$1" in
    --apply-all)
      APPLY=true
      REMOVE_TRACKED_GENERATED=true
      UNTRACK_SENSITIVE=true
      PRUNE_MIGRATIONS=true
      PRUNE_LEGACY=true
      HISTORY_SCAN=true
      ;;
    --apply) APPLY=true ;;
    --remove-tracked-generated) REMOVE_TRACKED_GENERATED=true ;;
    --untrack-sensitive) UNTRACK_SENSITIVE=true ;;
    --prune-migrations) PRUNE_MIGRATIONS=true ;;
    --prune-legacy) PRUNE_LEGACY=true ;;
    --history-scan) HISTORY_SCAN=true ;;
    --no-compose-check) CHECK_COMPOSE=false ;;
    --report-root)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --report-root requires a path." >&2; exit 2; }
      REPORT_ROOT="$1"
      ;;
    --backup-root)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --backup-root requires a path." >&2; exit 2; }
      BACKUP_ROOT="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if { $REMOVE_TRACKED_GENERATED || $UNTRACK_SENSITIVE || $PRUNE_MIGRATIONS || $PRUNE_LEGACY; } && ! $APPLY; then
  echo "ERROR: destructive options require --apply or --apply-all." >&2
  exit 2
fi

for cmd in git python3 awk sed grep find sort tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $cmd" >&2
    exit 1
  }
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || { echo "ERROR: run this inside a Git repository." >&2; exit 1; }
cd "$ROOT"

[[ -f docker-compose.yml ]] || {
  echo "ERROR: docker-compose.yml was not found at the repository root." >&2
  exit 1
}
[[ -d services && -d scripts && -d artifacts ]] || {
  echo "ERROR: this does not look like demo-apim-telco-environment." >&2
  exit 1
}

TS="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$REPORT_ROOT/$TS"
BACKUP_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$REPORT_DIR"
$APPLY && mkdir -p "$BACKUP_DIR"

REPORT="$REPORT_DIR/report.md"
ACTIONS="$REPORT_DIR/actions.log"
SENSITIVE_TSV="$REPORT_DIR/sensitive-findings.tsv"
SCRIPT_TSV="$REPORT_DIR/script-candidates.tsv"
DUPLICATE_TSV="$REPORT_DIR/duplicate-files.tsv"
GENERATED_TSV="$REPORT_DIR/generated-paths.tsv"

exec 3>>"$ACTIONS"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a /dev/fd/3; }
section() { printf '\n## %s\n\n' "$1" >>"$REPORT"; }
code_file() {
  printf '```text\n' >>"$REPORT"
  if [[ -s "$1" ]]; then cat "$1" >>"$REPORT"; else printf '(none)\n' >>"$REPORT"; fi
  printf '```\n' >>"$REPORT"
}
is_tracked() { git ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }
is_modified() {
  ! git diff --quiet -- "$1" || ! git diff --cached --quiet -- "$1"
}
external_references() {
  local candidate="$1" base
  base="$(basename "$candidate")"
  git grep -nF -- "$base" -- . 2>/dev/null \
    | awk -F: -v self="$candidate" \
      '$1 != self && $1 !~ /^\.repo-audit\// && $1 !~ /^\.repo-cleanup-backups\// {print}' \
    || true
}
backup_path() {
  local path="$1" target
  $APPLY || return 0
  [[ -e "$path" || -L "$path" ]] || return 0
  target="$BACKUP_DIR/files/$path"
  mkdir -p "$(dirname "$target")"
  if [[ -d "$path" && ! -L "$path" ]]; then
    mkdir -p "$target"
    cp -a "$path"/. "$target"/
  else
    cp -a "$path" "$target"
  fi
}

branch="$(git branch --show-current 2>/dev/null || true)"
commit="$(git rev-parse HEAD 2>/dev/null || true)"
cat >"$REPORT" <<EOF
# Repository cleanup audit

- Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- Repository: \`$(basename "$ROOT")\`
- Branch: \`${branch:-detached}\`
- Commit: \`${commit:-unknown}\`
- Apply mode: \`$APPLY\`

EOF

# ---------------------------------------------------------------------------
# 0. Recovery material before modifications.
# ---------------------------------------------------------------------------
section "Recovery material"
if $APPLY; then
  git status --short >"$BACKUP_DIR/status-before.txt"
  git diff --binary >"$BACKUP_DIR/working-tree.patch" || true
  git diff --cached --binary >"$BACKUP_DIR/index.patch" || true
  git ls-files -z >"$BACKUP_DIR/tracked-files-before.zlist"
  cp -a .gitignore "$BACKUP_DIR/gitignore.before" 2>/dev/null || true
  if git bundle create "$BACKUP_DIR/repository.bundle" --all >/dev/null 2>&1; then
    log "Created Git bundle: $BACKUP_DIR/repository.bundle"
  else
    log "Git bundle could not be created; patch backups are still available."
  fi
  printf 'Recovery artifacts were created under `%s`.\n' "$BACKUP_DIR" >>"$REPORT"
else
  printf 'Audit mode: no recovery material was needed because no changes were made.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 1. Harden .gitignore.
# ---------------------------------------------------------------------------
read -r -d '' IGNORE_BLOCK <<'EOF' || true

# Repository cleanup reports and local recovery material
.repo-audit/
.repo-cleanup-backups/

# Generated reset, restart, bootstrap and verification output
.reset-validation-logs/
.restart-backups/
.backups/
**/.reset-validation-logs/
**/.restart-backups/
**/.backups/
.tmp-*/
**/.tmp-*/

# Local environment and secret material
.env
.env.*
!.env.example
!.env.*.example
*.local.env
secrets/
credentials/
tokens/
**/secrets/
**/credentials/
**/tokens/
*.pem
*.key
*.p12
*.pfx
*.jks
*.keystore
*.truststore
!**/*.example.pem
!**/*.example.key

# Generated OAuth, DCR, token and bootstrap state
**/*oauth-runtime-state*.json
**/*oauth-application-state*.json
**/*bootstrap-runtime-state*.json
**/*application-keys*.json
**/*generated-token*.json
**/*dcr-response*.json
**/*access-token*.txt
**/*refresh-token*.txt

# Logs, traces and local HTTP captures
*.log
*.trace
*.har
*.retry
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# OS and editor files
.DS_Store
Thumbs.db
.idea/
.vscode/
*.swp
*.swo
*~

# Java, JavaScript and Python build output
**/target/
*.class
node_modules/
dist/
build/
coverage/
.nyc_output/
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/

# APICTL and temporary import/export workspaces
.apictl/
**/.apictl/
.tmp-service-catalog-import/
.tmp-service-catalog-import.zip
EOF

if $APPLY; then
  backup_path .gitignore
  touch .gitignore
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    elif [[ "$line" == \#* ]]; then
      grep -Fqx "$line" .gitignore || printf '\n%s\n' "$line" >>.gitignore
    else
      grep -Fqx "$line" .gitignore || printf '%s\n' "$line" >>.gitignore
    fi
  done <<<"$IGNORE_BLOCK"
  log "Hardened .gitignore idempotently."
fi

section ".gitignore hardening"
printf 'The following ignore policy is %s:\n\n' "$($APPLY && echo applied || echo recommended)" >>"$REPORT"
printf '```gitignore\n%s\n```\n' "$IGNORE_BLOCK" >>"$REPORT"

# ---------------------------------------------------------------------------
# 2. Inventory known generated paths.
# ---------------------------------------------------------------------------
python3 - "$ROOT" "$REPORT_ROOT" "$BACKUP_ROOT" >"$GENERATED_TSV" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
excluded_roots = [(root / sys.argv[2]).resolve(), (root / sys.argv[3]).resolve()]

known_dirs = {
    '.reset-validation-logs', '.restart-backups', '.backups',
    '.tmp-service-catalog-import', '__pycache__', '.pytest_cache',
    '.mypy_cache', '.nyc_output', 'coverage', 'node_modules',
}
build_dirs = {'target', 'dist', 'build'}
file_names = {'.DS_Store', 'Thumbs.db', '.tmp-service-catalog-import.zip'}
suffixes = ('.log', '.tmp', '.bak', '.backup', '.pyc', '.pyo', '.class', '.trace', '.har', '.retry')

for current, dirs, files in os.walk(root, topdown=True):
    current_path = Path(current).resolve()
    if current_path == root / '.git' or (root / '.git') in current_path.parents:
        dirs[:] = []
        continue
    if any(current_path == x or x in current_path.parents for x in excluded_roots):
        dirs[:] = []
        continue

    rel_current = current_path.relative_to(root)
    kept = []
    for d in dirs:
        p = current_path / d
        rel = p.relative_to(root)
        if d in known_dirs or d.startswith('.tmp-'):
            print(f'directory\t{rel.as_posix()}')
            continue
        if d in build_dirs and len(rel.parts) > 1:
            print(f'directory\t{rel.as_posix()}')
            continue
        kept.append(d)
    dirs[:] = kept

    for name in files:
        rel = (current_path / name).relative_to(root)
        if name in file_names or name.endswith(suffixes) or name.startswith(('npm-debug.log', 'yarn-error.log')):
            print(f'file\t{rel.as_posix()}')
PY
sort -u -o "$GENERATED_TSV" "$GENERATED_TSV"

GENERATED_REMOVED="$REPORT_DIR/generated-removed.txt"
GENERATED_TRACKED_REVIEW="$REPORT_DIR/generated-tracked-review.txt"
: >"$GENERATED_REMOVED"
: >"$GENERATED_TRACKED_REVIEW"

while IFS=$'\t' read -r _kind path; do
  [[ -n "$path" && ( -e "$path" || -L "$path" ) ]] || continue

  tracked=false
  if is_tracked "$path" || git ls-files -- "$path" | grep -q .; then
    tracked=true
  fi

  # Only these tracked locations are automatically safe to remove from Git.
  safe_tracked=false
  case "$path" in
    .reset-validation-logs|.reset-validation-logs/*|*/.reset-validation-logs|*/.reset-validation-logs/*|.restart-backups|.restart-backups/*|*/.restart-backups|*/.restart-backups/*|.backups|.backups/*|*/.backups|*/.backups/*)
      safe_tracked=true
      ;;
  esac

  if $tracked; then
    if $APPLY && $REMOVE_TRACKED_GENERATED && $safe_tracked; then
      backup_path "$path"
      git rm -r -f --ignore-unmatch -- "$path" >/dev/null
      printf '%s\n' "$path" >>"$GENERATED_REMOVED"
      log "Removed committed generated path: $path"
    else
      printf '%s\n' "$path" >>"$GENERATED_TRACKED_REVIEW"
    fi
  else
    if $APPLY; then
      rm -rf -- "$path"
      printf '%s\n' "$path" >>"$GENERATED_REMOVED"
      log "Removed untracked generated path: $path"
    fi
  fi
done <"$GENERATED_TSV"
sort -u -o "$GENERATED_REMOVED" "$GENERATED_REMOVED"
sort -u -o "$GENERATED_TRACKED_REVIEW" "$GENERATED_TRACKED_REVIEW"

section "Generated and transient artifacts"
printf 'Paths %s:\n\n' "$($APPLY && echo removed || echo detected)" >>"$REPORT"
code_file "$GENERATED_REMOVED"
printf '\nTracked generated-looking files retained for manual review:\n\n' >>"$REPORT"
code_file "$GENERATED_TRACKED_REVIEW"

# ---------------------------------------------------------------------------
# 3. Secret and sensitive-local-file scan. Values are never printed.
# ---------------------------------------------------------------------------
python3 - "$ROOT" >"$SENSITIVE_TSV" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0')

path_rules = [
    ('LOCAL_ENV', re.compile(r'(^|/)\.env(?:\.|$)', re.I)),
    ('PRIVATE_KEY_FILE', re.compile(r'\.(?:pem|key|p12|pfx|jks|keystore|truststore)$', re.I)),
    ('SECRET_DIRECTORY', re.compile(r'(^|/)(?:secrets|credentials|tokens)/', re.I)),
    ('RUNTIME_STATE', re.compile(r'(?:oauth|dcr|token|credential|bootstrap|application[-_]?keys?).*(?:state|response|keys?|token)\.(?:json|txt)$', re.I)),
]
content_rules = [
    ('PRIVATE_KEY', re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')),
    ('OPENAI_KEY', re.compile(r'\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b')),
    ('AWS_ACCESS_KEY', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('GITHUB_TOKEN', re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b')),
    ('GOOGLE_API_KEY', re.compile(r'\bAIza[0-9A-Za-z_-]{30,}\b')),
    ('SLACK_TOKEN', re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{10,}\b')),
    ('JWT', re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b')),
]
assignment = re.compile(
    r'(?i)\b(password|passwd|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token|api[_-]?key)\b'
    r'\s*[:=]\s*["\']?([^"\'\s,#}]+)'
)
placeholders = {
    '', 'admin', 'password', 'changeme', 'change-me', 'example', 'sample',
    'dummy', 'test', 'demo', 'replace_me', 'replace-me', 'your_key_here',
    'true', 'false', 'null', 'none', '********', '<redacted>', 'redacted',
}

def placeholder(value):
    value = value.lower().strip()
    return (
        value in placeholders or value.startswith(('$', '${', '<', 'process.env'))
        or 'example' in value or 'placeholder' in value or 'replace' in value
    )

for raw in paths:
    if not raw:
        continue
    rel = raw.decode('utf-8', 'surrogateescape')
    path = root / rel
    for kind, rule in path_rules:
        if rule.search(rel) and rel not in {'.env.example'} and not rel.endswith('.example'):
            print(f'{kind}\t{rel}\t0\ttracked local or sensitive path')
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b'\0' in data[:8192] or len(data) > 5_000_000:
        continue
    text = data.decode('utf-8', 'ignore')
    for line_no, line in enumerate(text.splitlines(), 1):
        for kind, rule in content_rules:
            if rule.search(line):
                print(f'{kind}\t{rel}\t{line_no}\tpossible secret material')
        for match in assignment.finditer(line):
            value = match.group(2)
            if len(value) >= 8 and not placeholder(value):
                print(f'SECRET_ASSIGNMENT\t{rel}\t{line_no}\t{match.group(1)} has a non-placeholder value')
PY
sort -u -o "$SENSITIVE_TSV" "$SENSITIVE_TSV"

if $APPLY && $UNTRACK_SENSITIVE && [[ -s "$SENSITIVE_TSV" ]]; then
  while IFS=$'\t' read -r kind path _line _finding; do
    case "$kind" in
      LOCAL_ENV|PRIVATE_KEY_FILE|SECRET_DIRECTORY|RUNTIME_STATE)
        [[ "$path" == ".env.example" || "$path" == *.example ]] && continue
        if is_tracked "$path"; then
          backup_path "$path"
          git rm --cached -- "$path" >/dev/null
          log "Untracked sensitive/local path and preserved its working copy: $path"
        fi
        ;;
    esac
  done <"$SENSITIVE_TSV"
fi

section "Security findings"
if [[ -s "$SENSITIVE_TSV" ]]; then
  printf '| Type | File | Line | Finding |\n|---|---|---:|---|\n' >>"$REPORT"
  while IFS=$'\t' read -r kind path line finding; do
    printf '| `%s` | `%s` | %s | %s |\n' "$kind" "$path" "$line" "$finding" >>"$REPORT"
  done <"$SENSITIVE_TSV"
else
  printf 'No obvious current-tree secrets were detected by the built-in scanner.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 4. Identify and safely prune one-time migration and legacy scripts.
# ---------------------------------------------------------------------------
PROTECTED_RE='^(scripts/)?(cleanup-repository|repository-hygiene|telco-demo-control|reset-with-telco-ai|complete-oauth-post-start|demo-env|pre-demo-check|status|curl-smoke-test|trace-transaction|register-[^/]+|publish-[^/]+|verify-[^/]+|test-[^/]+|generate-[^/]+)\.sh$'
LEGACY_RE='^(start|restart|destroy|stop|stop-demo|reset-demo|start-from-scratch|full-restart-demo|reset-and-validate-from-scratch|run-demo|run-demo-detached|run-with-apim|run-with-apim-detached|run-with-mi-risk|stop-with-mi-risk|run-with-observability|stop-with-observability|start-siddhi-runtime-enforcement)\.sh$'
: >"$SCRIPT_TSV"

while IFS= read -r path; do
  [[ "$path" == *.sh ]] || continue
  [[ "$path" =~ $PROTECTED_RE ]] && continue
  base="$(basename "$path")"
  kind=""
  if [[ "$base" =~ ^(fix[-_]|patch[-_]|repair[-_]|implement[-_]|install[-_]) ]] || [[ "$base" =~ -v[0-9]+\.sh$ ]]; then
    kind="migration"
  elif [[ "$base" =~ $LEGACY_RE ]]; then
    kind="legacy-entrypoint"
  else
    continue
  fi

  refs_file="$REPORT_DIR/refs-$(printf '%s' "$path" | tr '/ ' '__').txt"
  external_references "$path" >"$refs_file"
  refs="$(wc -l <"$refs_file" | tr -d ' ')"
  modified=false
  is_modified "$path" && modified=true
  mutator=false
  grep -Eq '(sed[[:space:]]+-i|apply_patch|git apply|cat[[:space:]]+>|write_text\(|perl[[:space:]]+-pi|python3?[[:space:]]+<<)' "$path" 2>/dev/null && mutator=true
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$path" "$refs" "$modified" "$mutator" >>"$SCRIPT_TSV"
done < <(git ls-files '*.sh')

section "Script cleanup decisions"
if [[ -s "$SCRIPT_TSV" ]]; then
  printf '| Class | Script | References | Modified | Source-mutating | Decision |\n|---|---|---:|---|---|---|\n' >>"$REPORT"
  while IFS=$'\t' read -r kind path refs modified mutator; do
    decision="retain"
    if [[ "$refs" == 0 && "$modified" == false ]]; then
      if [[ "$kind" == migration ]]; then
        decision="eligible for safe migration pruning"
      else
        decision="eligible for safe legacy pruning"
      fi
    elif [[ "$refs" != 0 ]]; then
      decision="retain: referenced by tracked content"
    else
      decision="retain: locally modified"
    fi
    printf '| `%s` | `%s` | %s | %s | %s | %s |\n' "$kind" "$path" "$refs" "$modified" "$mutator" "$decision" >>"$REPORT"
  done <"$SCRIPT_TSV"
else
  printf 'No migration-style or legacy lifecycle scripts were detected.\n' >>"$REPORT"
fi

if $APPLY && [[ -s "$SCRIPT_TSV" ]]; then
  while IFS=$'\t' read -r kind path refs modified _mutator; do
    should_prune=false
    [[ "$kind" == migration && "$PRUNE_MIGRATIONS" == true ]] && should_prune=true
    [[ "$kind" == legacy-entrypoint && "$PRUNE_LEGACY" == true ]] && should_prune=true
    $should_prune || continue

    if [[ "$refs" != 0 ]]; then
      log "Retained referenced $kind script: $path ($refs references)"
      continue
    fi
    if [[ "$modified" == true ]]; then
      log "Retained locally modified $kind script: $path"
      continue
    fi
    if is_tracked "$path"; then
      backup_path "$path"
      git rm -- "$path" >/dev/null
      log "Pruned unreferenced, unmodified $kind script: $path"
    fi
  done <"$SCRIPT_TSV"
fi

# ---------------------------------------------------------------------------
# 5. Exact duplicate inventory. Never auto-delete.
# ---------------------------------------------------------------------------
python3 - "$ROOT" >"$DUPLICATE_TSV" <<'PY'
import hashlib
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

root = Path(sys.argv[1])
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0')
groups = defaultdict(list)
for raw in paths:
    if not raw:
        continue
    rel = raw.decode('utf-8', 'surrogateescape')
    path = root / rel
    try:
        if not path.is_file() or path.stat().st_size == 0 or path.stat().st_size > 5_000_000:
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        continue
    groups[digest].append(rel)
for digest, members in sorted(groups.items()):
    if len(members) > 1:
        print(digest + '\t' + '\t'.join(sorted(members)))
PY

section "Exact duplicate tracked files"
if [[ -s "$DUPLICATE_TSV" ]]; then
  while IFS= read -r line; do
    digest="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    printf -- '- `%s`\n' "$digest" >>"$REPORT"
    while IFS= read -r member; do
      [[ -n "$member" ]] && printf '  - `%s`\n' "$member" >>"$REPORT"
    done < <(printf '%s' "$rest" | tr '\t' '\n')
  done <"$DUPLICATE_TSV"
  printf '\nNo duplicates were removed. In particular, `contracts/` and `artifacts/contracts/` may serve different Docker build contexts.\n' >>"$REPORT"
else
  printf 'No exact duplicate tracked files were detected.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 6. Static validation.
# ---------------------------------------------------------------------------
section "Shell syntax validation"
SHELL_RESULT="$REPORT_DIR/shell-validation.txt"
: >"$SHELL_RESULT"
shell_failed=false
while IFS= read -r script; do
  [[ -f "$script" ]] || continue
  if ! bash -n "$script" 2>>"$SHELL_RESULT"; then
    printf 'FAILED: %s\n' "$script" >>"$SHELL_RESULT"
    shell_failed=true
  fi
done < <(git ls-files '*.sh')
if $shell_failed; then
  printf 'One or more tracked shell scripts failed `bash -n`:\n\n' >>"$REPORT"
  code_file "$SHELL_RESULT"
else
  printf 'All remaining tracked shell scripts passed `bash -n`.\n' >>"$REPORT"
fi

section "Git whitespace validation"
WHITESPACE_RESULT="$REPORT_DIR/git-diff-check.txt"
if git diff --check >"$WHITESPACE_RESULT" 2>&1; then
  printf '`git diff --check` passed.\n' >>"$REPORT"
else
  printf '`git diff --check` reported whitespace problems:\n\n' >>"$REPORT"
  code_file "$WHITESPACE_RESULT"
fi

# ---------------------------------------------------------------------------
# 7. Docker Compose validation.
# ---------------------------------------------------------------------------
section "Docker Compose validation"
COMPOSE_RESULT="$REPORT_DIR/compose-validation.txt"
: >"$COMPOSE_RESULT"
if $CHECK_COMPOSE; then
  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
  else
    DC=()
  fi

  if ((${#DC[@]})); then
    compose_files=(docker-compose.yml)
    for file in \
      docker-compose.kafka.yml \
      docker-compose.opa.yml \
      docker-compose.central-policy.yml \
      docker-compose.mi.yml \
      docker-compose.mi-runtime-memory.yml \
      docker-compose.oauth-business-controls.yml \
      docker-compose.commercial.yml \
      docker-compose.mi.soap.yml \
      docker-compose.observability.yml \
      docker-compose.audit-siem.yml \
      docker-compose.siddhi-runtime.yml \
      docker-compose.ai.yml \
      docker-compose.runtime-persistence.yml; do
      [[ -f "$file" ]] && compose_files+=("$file")
    done

    args=()
    for file in "${compose_files[@]}"; do args+=(-f "$file"); done
    env_args=()
    if [[ -n "${TELCO_AI_ENV_FILE:-}" && -f "${TELCO_AI_ENV_FILE}" ]]; then
      env_args=(--env-file "${TELCO_AI_ENV_FILE}")
    fi

    if "${DC[@]}" ${env_args[@]+${env_args[@]+"${env_args[@]}"}} "${args[@]}" config --quiet >"$COMPOSE_RESULT" 2>&1; then
      printf 'The combined available Compose topology validated successfully:\n\n' >>"$REPORT"
      printf '```text\n%s\n```\n' "${compose_files[*]}" >>"$REPORT"
    else
      printf 'Combined Compose validation failed. Optional overlays may require local environment values; inspect:\n\n' >>"$REPORT"
      code_file "$COMPOSE_RESULT"
    fi
  else
    printf 'Docker Compose is unavailable, so Compose validation was skipped.\n' >>"$REPORT"
  fi
else
  printf 'Compose validation was disabled with `--no-compose-check`.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 8. Optional purpose-built history scan.
# ---------------------------------------------------------------------------
section "Git history secret scan"
if $HISTORY_SCAN; then
  if command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS_REPORT="$REPORT_DIR/gitleaks.json"
    if gitleaks git --redact --report-format json --report-path "$GITLEAKS_REPORT" . >/dev/null 2>&1; then
      printf 'Gitleaks completed without findings.\n' >>"$REPORT"
    else
      printf 'Gitleaks found possible historical secrets. Review `%s`; values are redacted.\n' "$GITLEAKS_REPORT" >>"$REPORT"
    fi
  else
    printf '`gitleaks` is not installed. Install it and rerun with `--history-scan`; the cleanup itself continued.\n' >>"$REPORT"
  fi
else
  printf 'Not requested. Use `--history-scan` or `--apply-all`.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 9. Important architectural warning: runtime source mutation.
# ---------------------------------------------------------------------------
section "Runtime source-mutation warning"
MUTATION_RESULT="$REPORT_DIR/runtime-source-mutation.txt"
: >"$MUTATION_RESULT"
if [[ -f scripts/telco-demo-control.sh ]]; then
  grep -nE 'patch_repository|write_text\(|sed[[:space:]]+-i|cat[[:space:]]+>.*docker-compose|Path\(' \
    scripts/telco-demo-control.sh >"$MUTATION_RESULT" 2>/dev/null || true
fi
if [[ -s "$MUTATION_RESULT" ]]; then
  printf 'The lifecycle controller still appears to rewrite repository source at runtime. This script does **not** remove that code automatically, because every successful patch must first be folded into its authoritative source file and retested. Matches:\n\n' >>"$REPORT"
  code_file "$MUTATION_RESULT"
else
  printf 'No obvious runtime source-rewriting pattern was detected in the canonical lifecycle controller.\n' >>"$REPORT"
fi

# ---------------------------------------------------------------------------
# 10. Final result.
# ---------------------------------------------------------------------------
STATUS_FILE="$REPORT_DIR/git-status-after.txt"
DIFF_STAT_FILE="$REPORT_DIR/git-diff-stat.txt"
git status --short >"$STATUS_FILE"
git diff --stat >"$DIFF_STAT_FILE" || true

section "Resulting Git status"
code_file "$STATUS_FILE"
section "Resulting diff summary"
code_file "$DIFF_STAT_FILE"

section "Required manual review before commit"
cat >>"$REPORT" <<'EOF'
1. Review every staged deletion with `git status --short` and `git diff --cached --stat`.
2. Review `.gitignore` and ensure no required example certificate or fixture is hidden.
3. Inspect any retained migration script: it was retained because it is referenced or locally modified.
4. Do not remove mirrored contracts until all Docker/build/bootstrap consumers use one canonical location.
5. Fold every successful `patch_repository()` change into committed source, test a clean reset, and only then remove the runtime patch block.
6. Rotate any real credential that was ever committed; `.gitignore` and `git rm --cached` do not erase Git history.
7. A historical secret requires `git filter-repo` or BFG plus a force-push coordinated with all repository users.
EOF

printf '\nRepository audit complete.\n'
printf 'Report: %s\n' "$REPORT"
printf 'Actions: %s\n' "$ACTIONS"
if $APPLY; then
  printf 'Recovery: %s\n' "$BACKUP_DIR"
  printf '\nReview now:\n'
  printf '  git status --short\n'
  printf '  git diff -- .gitignore\n'
  printf '  git diff --stat\n'
  printf '  git diff\n'
  printf '  git diff --cached --stat\n'
else
  printf 'No files were changed. Apply the full safe cleanup with:\n'
  printf '  %s --apply-all\n' "$0"
fi

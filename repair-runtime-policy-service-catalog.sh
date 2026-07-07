#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-scripts/register-mi-service-catalog.sh}"
[[ -f "$TARGET" ]] || { echo "ERROR: missing $TARGET" >&2; exit 1; }

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
service_name = 'RuntimePolicyAlertAPI'
service = '''
    {
        "name": "RuntimePolicyAlertAPI",
        "title": "Runtime Policy Alert API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator: MI service that validates APIM runtime throttling "
            "events and publishes them to the telco.runtime.policy.alerts Kafka topic."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/runtime-policy-alerts/v1"
        ),
        "operations": [
            ("get", "/health", "Check runtime policy alert integration health"),
            ("post", "/events", "Publish a normalized runtime policy alert"),
        ],
    },
'''

if f'"name": "{service_name}"' not in text:
    list_match = re.search(r'(?m)^\s*services\s*=\s*\[', text)
    operation_match = re.search(r'(?m)^\s*def\s+operation\s*\(', text)
    if not list_match or not operation_match or operation_match.start() <= list_match.end():
        raise SystemExit(f'Cannot patch {p}: generated services list boundaries were not found')

    region = text[list_match.end():operation_match.start()]
    close_relative = region.rfind(']')
    if close_relative < 0:
        raise SystemExit(f'Cannot patch {p}: generated services list has no closing bracket')

    insert_at = list_match.end() + close_relative
    prefix = text[:insert_at]
    if prefix and not prefix.endswith('\n'):
        prefix += '\n'
    text = prefix + service + text[insert_at:]

expected_match = re.search(r'(?m)^\s*EXPECTED_SERVICES\s*=\s*\(', text)
if not expected_match:
    raise SystemExit(f'Cannot patch {p}: EXPECTED_SERVICES array was not found')

loop_match = re.search(
    r'(?m)^\s*for\s+required\s+in\s+"\$\{EXPECTED_SERVICES\[@\]\}"',
    text[expected_match.end():],
)
if not loop_match:
    raise SystemExit(f'Cannot patch {p}: EXPECTED_SERVICES verification loop was not found')

loop_start = expected_match.end() + loop_match.start()
region = text[expected_match.end():loop_start]
if service_name not in region:
    close_relative = region.rfind(')')
    if close_relative < 0:
        raise SystemExit(f'Cannot patch {p}: EXPECTED_SERVICES has no closing parenthesis')
    insert_at = expected_match.end() + close_relative
    prefix = text[:insert_at]
    if prefix and not prefix.endswith('\n'):
        prefix += '\n'
    text = prefix + f'  {service_name}\n' + text[insert_at:]

text = text.replace('All five MI services are registered.', 'All six MI services are registered.')
p.write_text(text, encoding='utf-8')
PY

bash -n "$TARGET"
grep -n 'RuntimePolicyAlertAPI\|All six MI services' "$TARGET"
echo "Service Catalog registration patched successfully."

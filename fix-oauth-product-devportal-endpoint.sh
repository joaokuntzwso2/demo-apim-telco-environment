#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

TARGET="scripts/verify-oauth-consent-risk-controls.sh"

fail() {
  printf '[oauth-product-endpoint-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$TARGET" ]] || fail "Missing $TARGET"
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

timestamp="$(date +%Y%m%d-%H%M%S)"
backup="${TARGET}.before-product-endpoint-fix.${timestamp}"
cp "$TARGET" "$backup"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start = text.find('devportal_products=""')
end = text.find("partner_application_id=", start)

if start < 0 or end < 0:
    raise SystemExit(
        "[oauth-product-endpoint-fix][FAIL] "
        "Could not locate the API Product DevPortal verification section."
    )

replacement = r'''devportal_products=""
oauth_product_name="SubscriberAuthorizationBusinessControlsProduct"

for attempt in $(seq 1 60); do
  if ! devportal_products="$(
    curl -kfsS \
      -H "Authorization: Bearer ${devportal_token}" \
      "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
  )"; then
    fail "Could not retrieve the unified Developer Portal API listing."
    devportal_products='{"list":[]}'
  fi

  if jq -e \
    --arg name "${oauth_product_name}" '
      any(
        (.list // .data // [])[]?;
        .name == $name and
        (.version // "") == "1.0.0"
      )
    ' \
    <<<"${devportal_products}" >/dev/null 2>&1
  then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API Product ${oauth_product_name} Developer Portal indexing (${attempt}/60)."
  sleep 2
done

if jq -e \
  --arg name "${oauth_product_name}" '
    any(
      (.list // .data // [])[]?;
      .name == $name and
      (.version // "") == "1.0.0"
    )
  ' \
  <<<"${devportal_products}" >/dev/null 2>&1
then
  product_type="$(
    jq -r \
      --arg name "${oauth_product_name}" '
        first(
          (.list // .data // [])[]?
          | select(
              .name == $name and
              (.version // "") == "1.0.0"
            )
          | (.type // "APIProduct")
        ) // "APIProduct"
      ' \
      <<<"${devportal_products}"
  )"

  pass "Native API Product is visible and subscribable in the Developer Portal (${product_type})."
else
  fail "Native API Product is not visible in the unified Developer Portal listing."

  echo "[oauth-controls-verify] Developer Portal entries currently visible:" >&2

  jq -r '
    (.list // .data // [])[]?
    | "  \(.name // "-"):\(.version // "-") type=\(.type // "-")"
  ' \
    <<<"${devportal_products}" >&2 ||
    printf '%s\n' "${devportal_products}" >&2
fi

'''

updated = text[:start] + replacement + text[end:]

if "/api/am/devportal/v3/api-products" in updated:
    raise SystemExit(
        "[oauth-product-endpoint-fix][FAIL] "
        "The obsolete /api-products endpoint is still present."
    )

path.write_text(updated, encoding="utf-8")

print(
    "[oauth-product-endpoint-fix] "
    "API Product lookup now uses the unified DevPortal /apis endpoint."
)
PY

bash -n "$TARGET"

grep -q \
  '/api/am/devportal/v3/apis?limit=1000' \
  "$TARGET" ||
  fail "Unified DevPortal endpoint was not installed."

if grep -q \
  '/api/am/devportal/v3/api-products' \
  "$TARGET"
then
  cp "$backup" "$TARGET"
  fail "Obsolete endpoint remains; original verifier restored."
fi

echo
echo "[oauth-product-endpoint-fix] Fix completed."
echo "[oauth-product-endpoint-fix] Backup: $backup"

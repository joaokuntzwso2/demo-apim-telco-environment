#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml}"

if [[ ! -f "$TARGET" ]]; then
  echo "[apim-developer-experience-config] ERROR: deployment.toml not found: $TARGET" >&2
  exit 1
fi

upsert_toml_key() {
  local table="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v wanted_table="[${table}]" -v wanted_key="$key" -v wanted_value="$value" '
    BEGIN {
      inside = 0
      section_found = 0
      key_written = 0
    }

    /^\[/ {
      if (inside && !key_written) {
        print wanted_key " = " wanted_value
        key_written = 1
      }
      inside = ($0 == wanted_table)
      if (inside) {
        section_found = 1
        key_written = 0
      }
    }

    {
      if (inside && $0 ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
        if (!key_written) {
          print wanted_key " = " wanted_value
          key_written = 1
        }
        next
      }
      print
    }

    END {
      if (inside && !key_written) {
        print wanted_key " = " wanted_value
        key_written = 1
      }
      if (!section_found) {
        print ""
        print wanted_table
        print wanted_key " = " wanted_value
      }
    }
  ' "$TARGET" > "$tmp"

  cat "$tmp" > "$TARGET"
  rm -f "$tmp"
}

upsert_toml_key \
  "apim.publisher" \
  "enable_api_doc_visibility" \
  '"true"'

upsert_toml_key \
  "apim.publisher" \
  "supported_document_types" \
  '"pdf, txt, doc, docx, xls, xlsx, odt, ods, json, yaml, yml, md"'

upsert_toml_key \
  "apim.sdk" \
  "supported_languages" \
  '["android", "java", "javascript", "jmeter", "python", "csharp", "php", "swift5", "go"]'

echo "[apim-developer-experience-config] Developer Portal documentation and SDK settings merged."

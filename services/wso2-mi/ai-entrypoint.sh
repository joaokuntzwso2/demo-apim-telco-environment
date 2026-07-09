#!/usr/bin/env sh
set -eu
: "${OPENAI_API_KEY:=}"
: "${AI_LLM_BASE_URL:=https://api.openai.com/v1}"
: "${AI_MODEL_STANDARD:=gpt-4o-mini}"
: "${AI_MODEL_ADVANCED:=gpt-4o}"
: "${AI_MAX_OUTPUT_TOKENS_STANDARD:=700}"
: "${AI_MAX_OUTPUT_TOKENS_ADVANCED:=1200}"
: "${AI_TOOL_TIMEOUT_SECONDS:=12}"
: "${AI_MAX_HISTORY:=6}"
HOME_DIR="${WSO2_SERVER_HOME:-/home/wso2carbon/wso2mi-4.6.0}"
SYNAPSE="${HOME_DIR}/repository/deployment/server/synapse-configs/default"
mkdir -p "${SYNAPSE}/local-entries"
xml_escape(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
cat > "${SYNAPSE}/local-entries/TELCO_OPENAI_CONNECTION.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<localEntry key="TELCO_OPENAI_CONNECTION" xmlns="http://ws.apache.org/ns/synapse">
  <ai.init>
    <connectionType>OPEN_AI</connectionType>
    <name>TELCO_OPENAI_CONNECTION</name>
    <apiKey>$(xml_escape "$OPENAI_API_KEY")</apiKey>
    <baseUrl>$(xml_escape "$AI_LLM_BASE_URL")</baseUrl>
  </ai.init>
</localEntry>
XML
find "${SYNAPSE}/sequences" -type f -name 'TelcoAi*Agent.xml' -print | while IFS= read -r f; do
  sed -i \
    -e "s|__AI_MODEL_STANDARD__|${AI_MODEL_STANDARD}|g" \
    -e "s|__AI_MODEL_ADVANCED__|${AI_MODEL_ADVANCED}|g" \
    -e "s|__AI_MAX_OUTPUT_TOKENS_STANDARD__|${AI_MAX_OUTPUT_TOKENS_STANDARD}|g" \
    -e "s|__AI_MAX_OUTPUT_TOKENS_ADVANCED__|${AI_MAX_OUTPUT_TOKENS_ADVANCED}|g" \
    -e "s|__AI_TOOL_TIMEOUT_SECONDS__|${AI_TOOL_TIMEOUT_SECONDS}|g" \
    -e "s|__AI_MAX_HISTORY__|${AI_MAX_HISTORY}|g" "$f"
done
sed -i -e "s|__AI_MODEL_STANDARD__|${AI_MODEL_STANDARD}|g" -e "s|__AI_MODEL_ADVANCED__|${AI_MODEL_ADVANCED}|g" \
  "${SYNAPSE}/sequences/TelcoAiBuildResponse.xml"
exec /home/wso2carbon/wait-for-apim.sh

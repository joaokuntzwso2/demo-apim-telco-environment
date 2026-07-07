#!/bin/sh
set -eu
CONF="${1:-/home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml}"
TMP="${CONF}.observability.tmp"
awk '
function emit_otel() {
  print "remote_tracer.enable = true"
  print "remote_tracer.name = \"otlp\""
  print "remote_tracer.url = \"http://otel-collector:4317/v1/traces\""
}
BEGIN { section=""; seen_otel=0 }
{
  if ($0 ~ /^\[/) {
    if (section == "otel") emit_otel()
    section=""
    if ($0 == "[apim.open_telemetry]") { section="otel"; seen_otel=1 }
    print
    next
  }
  if (section == "otel" && $0 ~ /^[[:space:]]*remote_tracer\.(enable|name|url)[[:space:]]*=/) next
  print
}
END {
  if (section == "otel") emit_otel()
  if (!seen_otel) {
    print ""
    print "# BEGIN TELCO APIM OBSERVABILITY"
    print "[apim.open_telemetry]"
    emit_otel()
    print "# END TELCO APIM OBSERVABILITY"
  }
}
' "$CONF" > "$TMP"
mv "$TMP" "$CONF"

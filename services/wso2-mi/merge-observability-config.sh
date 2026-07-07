#!/bin/sh
set -eu
CONF="${1:-/home/wso2carbon/wso2mi-4.6.0/conf/deployment.toml}"
TMP="${CONF}.observability.tmp"
awk '
function emit_mediation() {
  print "flow.statistics.capture_all = true"
  print "stat.tracer.collect_payloads = false"
  print "stat.tracer.collect_mediation_properties = true"
}
function emit_otel() {
  print "enable = true"
  print "logs = true"
  print "type = \"otlp\""
  print "protocol = \"http\""
  print "url = \"http://otel-collector:4318/v1/traces\""
  print "filtered.mediator.names = \"LogMediator,PropertyMediator\""
  print "custom.span.header.tags = \"activityID,X-Correlation-ID,traceparent,organization-id,source-id,application-id\""
}
BEGIN { section=""; seen_mediation=0; seen_otel=0 }
{
  if ($0 ~ /^\[/) {
    if (section == "mediation") emit_mediation()
    if (section == "otel") emit_otel()
    section=""
    if ($0 == "[mediation]") { section="mediation"; seen_mediation=1 }
    else if ($0 == "[opentelemetry]") { section="otel"; seen_otel=1 }
    print
    next
  }
  if (section == "mediation" && $0 ~ /^[[:space:]]*(flow\.statistics\.capture_all|stat\.tracer\.collect_payloads|stat\.tracer\.collect_mediation_properties)[[:space:]]*=/) next
  if (section == "otel" && $0 ~ /^[[:space:]]*(enable|logs|type|protocol|url|filtered\.mediator\.names|custom\.span\.header\.tags)[[:space:]]*=/) next
  print
}
END {
  if (section == "mediation") emit_mediation()
  if (section == "otel") emit_otel()
  if (!seen_mediation) {
    print ""
    print "# BEGIN TELCO MI OBSERVABILITY"
    print "[mediation]"
    emit_mediation()
  }
  if (!seen_otel) {
    print ""
    print "[opentelemetry]"
    emit_otel()
    print "# END TELCO MI OBSERVABILITY"
  }
}
' "$CONF" > "$TMP"
mv "$TMP" "$CONF"
if ! grep -Fq 'org.wso2.micro.integrator.observability.metric.handler.MetricHandler' "$CONF"; then
  cat >> "$CONF" <<'BLOCK'

[[synapse_handlers]]
name = "CustomObservabilityHandler"
class = "org.wso2.micro.integrator.observability.metric.handler.MetricHandler"
BLOCK
fi

#!/usr/bin/env bash
set -euo pipefail

endpoint_dir="services/wso2-mi/synapse-configs/default/endpoints"
sequence_dir="services/wso2-mi/synapse-configs/default/sequences"

if [[ ! -d "$endpoint_dir" || ! -d "$sequence_dir" ]]; then
  echo "[verify-mi-resilience] ERROR: run from the repository root." >&2
  exit 1
fi

endpoint_files=(
  CrmLegacyFailoverEndpoint.xml
  SimSwapFailoverEndpoint.xml
  DeviceLocationFailoverEndpoint.xml
  OssLegacyFailoverEndpoint.xml
  LegacyBillingSoapFailoverEndpoint.xml
)

required_endpoint_patterns=(
  '<failover'
  '<timeout>'
  '<responseAction>fault</responseAction>'
  '<suspendOnFailure>'
  '<initialDuration>'
  '<progressionFactor>'
  '<maximumDuration>'
  '<markForSuspension>'
)

failures=0

for file_name in "${endpoint_files[@]}"; do
  file="${endpoint_dir}/${file_name}"
  if [[ ! -f "$file" ]]; then
    echo "[verify-mi-resilience] MISSING ENDPOINT: $file" >&2
    failures=$((failures + 1))
    continue
  fi

  endpoint_failures=0

  for pattern in "${required_endpoint_patterns[@]}"; do
    # The SOAP modernization endpoint deliberately sends the configured
    # transport failures directly to suspendOnFailure. Requiring
    # markForSuspension here would change the endpoint from immediate
    # circuit opening to Timeout-state retries before suspension.
    if [[ "$file_name" == "LegacyBillingSoapFailoverEndpoint.xml" \
          && "$pattern" == "<markForSuspension>" ]]; then
      continue
    fi

    if ! grep -Fq "$pattern" "$file"; then
      echo "[verify-mi-resilience] MISSING '${pattern}' in ${file_name}" >&2
      failures=$((failures + 1))
      endpoint_failures=$((endpoint_failures + 1))
    fi
  done

  # The final SOAP DR child must explicitly terminate the retry/failover
  # loop for the configured transport failures.
  if [[ "$file_name" == "LegacyBillingSoapFailoverEndpoint.xml" ]]; then
    for pattern in "<retryConfig>" "<disabledErrorCodes>"; do
      if ! grep -Fq "$pattern" "$file"; then
        echo "[verify-mi-resilience] MISSING '${pattern}' in ${file_name}" >&2
        failures=$((failures + 1))
        endpoint_failures=$((endpoint_failures + 1))
      fi
    done
  fi

  if (( endpoint_failures == 0 )); then
    echo "[verify-mi-resilience] ENDPOINT OK: ${file_name}"
  fi
done

sequence_checks=(
  "InitializeCorrelationSequence.xml:X-Correlation-ID"
  "RiskAssessmentFaultSequence.xml:HTTP_SC"
  "RiskAdapterFallbackSequence.xml:partial"
  "BillingModernizationTransportFaultSequence.xml:HTTP_SC"
  "BillingModernizationSoapFaultSequence.xml:HTTP_SC"
)

for check in "${sequence_checks[@]}"; do
  file_name="${check%%:*}"
  pattern="${check#*:}"
  file="${sequence_dir}/${file_name}"

  if [[ ! -f "$file" ]]; then
    echo "[verify-mi-resilience] MISSING SEQUENCE: $file" >&2
    failures=$((failures + 1))
    continue
  fi

  if ! grep -Fqi "$pattern" "$file"; then
    echo "[verify-mi-resilience] MISSING '${pattern}' in ${file_name}" >&2
    failures=$((failures + 1))
  else
    echo "[verify-mi-resilience] SEQUENCE OK: ${file_name}"
  fi
done

if (( failures > 0 )); then
  echo "[verify-mi-resilience] FAILED with ${failures} issue(s)." >&2
  exit 1
fi

echo "[verify-mi-resilience] PASS: MI failover, timeout, endpoint suspension/circuit breaking, correlation and fault handling are present."

#!/usr/bin/env bash
set -euo pipefail

# Runtime enforcement for the Siddhi controls in demo-apim-telco-environment.
# Run from the repository root. Safe to run repeatedly.

ROOT="${1:-$PWD}"
cd "$ROOT"

log() { printf '\n[siddhi-runtime-install] %s\n' "$*"; }
fail() { printf '\n[siddhi-runtime-install] ERROR: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || fail "Required repository file is missing: $1"; }
write_file() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target"
  log "Wrote $target"
}

require_file docker-compose.yml
require_file services/wso2-apim/Dockerfile
require_file services/wso2-mi/Dockerfile
require_file services/wso2-mi/conf/file.properties
require_file services/telco-backend/src/server.js
require_file services/telco-backend/src/kafka-broker.js
require_file services/apim-bootstrapper/package.json
require_file scripts/register-mi-service-catalog.sh
require_file contracts/openapi/network-slice.openapi.yaml
require_file artifacts/contracts/openapi/network-slice.openapi.yaml
require_file artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json

log "Installing APIM custom throttling policies with runtime API matching"
write_file artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json <<'JSON'
[
  {
    "policyName": "TelcoSiddhiQoDAssuranceBurstPolicy",
    "displayName": "Telco Siddhi QoD Assurance Burst Policy",
    "description": "Runtime APIM custom throttling policy for the QoD operation exposed by NetworkSliceAPI. The demo threshold is intentionally small so the 429 and alert path can be verified deterministically.",
    "keyTemplate": "$apiContext:$apiVersion",
    "isDeployed": true,
    "businessStory": "Protect shared 5G Quality-on-Demand assurance capacity from burst traffic while retaining API, application, partner and correlation evidence for operations and settlement review.",
    "siddhiQuery": "FROM RequestStream\nSELECT apiContext, apiVersion, ((apiContext == '/network-slice/v1' or apiContext == '/network-slice/v1/1.0.0') and apiVersion == '1.0.0') AS isEligible, str:concat(apiContext,':',apiVersion) as throttleKey\nINSERT INTO EligibilityStream;\n\nFROM EligibilityStream[isEligible==true]#throttler:timeBatch(5 sec)\nSELECT throttleKey, (count(throttleKey) >= 9) as isThrottled, expiryTimeStamp group by throttleKey\nINSERT ALL EVENTS into ResultStream;"
  },
  {
    "policyName": "TelcoSiddhiSimSwapFraudFairUsePolicy",
    "displayName": "Telco Siddhi SIM Swap Fraud Fair Use Policy",
    "description": "Runtime APIM custom throttling policy for OpenGatewaySimSwapRiskAPI. Fair use is enforced per APIM application, API context and version.",
    "keyTemplate": "$appId:$apiContext:$apiVersion",
    "isDeployed": true,
    "businessStory": "Prevent one bank, wallet or marketplace application from consuming disproportionate SIM Swap fraud capacity while preserving evidence needed for partner operations and commercial governance.",
    "siddhiQuery": "FROM RequestStream\nSELECT appId, apiContext, apiVersion, ((apiContext == '/open-gateway/sim-swap/v1' or apiContext == '/open-gateway/sim-swap/v1/1.0.0') and apiVersion == '1.0.0') AS isEligible, str:concat(appId,':',apiContext,':',apiVersion) as throttleKey\nINSERT INTO EligibilityStream;\n\nFROM EligibilityStream[isEligible==true]#throttler:timeBatch(15 sec)\nSELECT throttleKey, (count(throttleKey) >= 6) as isThrottled, expiryTimeStamp group by throttleKey\nINSERT ALL EVENTS into ResultStream;"
  }
]
JSON

log "Installing the APIM Classic Gateway throttle-out sequence"
write_file services/wso2-apim/sequences/_throttle_out_handler_.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse" name="_throttle_out_handler_" trace="disable">
    <!-- Preserve the standard APIM throttle analytics/CORS behavior. -->
    <property name="X-JWT-Assertion" scope="transport" action="remove"/>
<sequence key="_cors_request_handler_"/>

    <!-- Resolve correlation, partner, API and application identity before responding. -->
    <property name="telco.errorCode" expression="get-property('ERROR_CODE')" type="STRING"/>
    <filter xpath="not(string-length(normalize-space($ctx:telco.errorCode)) &gt; 0)">
        <then><property name="telco.errorCode" value="900800" type="STRING"/></then>
    </filter>
    <property name="telco.correlationId" expression="get-property('transport','X-Correlation-ID')" type="STRING"/>
    <filter xpath="not(string-length(normalize-space($ctx:telco.correlationId)) &gt; 0)">
        <then><property name="telco.correlationId" expression="get-property('MessageID')" type="STRING"/></then>
    </filter>
    <property name="telco.partnerId" expression="get-property('transport','X-Partner-Id')" type="STRING"/>
    <filter xpath="not(string-length(normalize-space($ctx:telco.partnerId)) &gt; 0)">
        <then><property name="telco.partnerId" value="unknown-partner" type="STRING"/></then>
    </filter>
    <property name="telco.apiContext" expression="get-property('api.ut.context')" type="STRING"/>
    <property name="telco.apiVersion" expression="get-property('api.ut.api_version')" type="STRING"/>
    <property name="telco.apiName" expression="get-property('api.ut.api')" type="STRING"/>
    <property name="telco.applicationId" expression="get-property('api.ut.application.id')" type="STRING"/>
    <property name="telco.applicationName" expression="get-property('api.ut.application.name')" type="STRING"/>

    <!-- Error 900806 is APIM's custom-policy throttle outcome. Other APIM
         throttling failures retain a normalized generic response and do not
         create a false telco business-control alert. -->
    <filter source="$ctx:telco.errorCode" regex="^900806$">
        <then>
            <property name="telco.isRuntimePolicy" value="false" type="STRING"/>
            <property name="telco.policyName" value="APIMCustomThrottlePolicy" type="STRING"/>
            <property name="telco.rateLimit" value="0" type="STRING"/>
            <property name="telco.retryAfter" value="1" type="STRING"/>
            <property name="telco.rateLimitReset" value="1" type="STRING"/>
            <switch source="$ctx:telco.apiContext">
                <case regex="^/open-gateway/sim-swap/v1(/1\\.0\\.0)?$">
                    <property name="telco.isRuntimePolicy" value="true" type="STRING"/>
                    <property name="telco.policyName" value="TelcoSiddhiSimSwapFraudFairUsePolicy" type="STRING"/>
                    <property name="telco.rateLimit" value="6" type="STRING"/>
                    <property name="telco.retryAfter" value="15" type="STRING"/>
                    <property name="telco.rateLimitReset" value="15" type="STRING"/>
                </case>
                <case regex="^/network-slice/v1(/1\\.0\\.0)?$">
                    <property name="telco.isRuntimePolicy" value="true" type="STRING"/>
                    <property name="telco.policyName" value="TelcoSiddhiQoDAssuranceBurstPolicy" type="STRING"/>
                    <property name="telco.rateLimit" value="9" type="STRING"/>
                    <property name="telco.retryAfter" value="5" type="STRING"/>
                    <property name="telco.rateLimitReset" value="5" type="STRING"/>
                </case>
                <default/>
            </switch>

            <filter source="$ctx:telco.isRuntimePolicy" regex="^true$">
                <then>
                    <!-- Publish the alert asynchronously through a genuine MI integration API.
                         continueParent keeps alert delivery failure from replacing the client-facing 429. -->
                    <clone continueParent="true">
                        <target>
                            <sequence>
                                <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
                                <property name="REST_URL_POSTFIX" scope="axis2" action="remove"/>
                                <property name="NO_ENTITY_BODY" scope="axis2" action="remove"/>
                                <!-- Fire-and-forget alert publication. Do not register a
                                     response callback on the throttled client flow. -->
                                <property name="OUT_ONLY" value="true" type="STRING"/>
                                <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
                                <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
                                <property name="Authorization" scope="transport" action="remove"/>
                                <property name="X-Correlation-ID" expression="$ctx:telco.correlationId" scope="transport" type="STRING"/>
                                <payloadFactory media-type="json">
                                    <format>{"eventType":"TELCO_RUNTIME_POLICY_THROTTLED","eventVersion":"1.0","occurredAt":"$1","policyName":"$2","partnerId":"$3","apiName":"$4","apiContext":"$5","apiVersion":"$6","applicationId":"$7","applicationName":"$8","correlationId":"$9","httpStatus":429,"errorCode":"900806","retryAfterSeconds":$10,"rateLimit":$11,"source":"WSO2-APIM-4.7-Classic-Gateway"}</format>
                                    <args>
                                        <arg evaluator="xml" expression="get-property('SYSTEM_DATE', &quot;yyyy-MM-dd'T'HH:mm:ss.SSSXXX&quot;)"/>
                                        <arg evaluator="xml" expression="$ctx:telco.policyName"/>
                                        <arg evaluator="xml" expression="$ctx:telco.partnerId"/>
                                        <arg evaluator="xml" expression="$ctx:telco.apiName"/>
                                        <arg evaluator="xml" expression="$ctx:telco.apiContext"/>
                                        <arg evaluator="xml" expression="$ctx:telco.apiVersion"/>
                                        <arg evaluator="xml" expression="$ctx:telco.applicationId"/>
                                        <arg evaluator="xml" expression="$ctx:telco.applicationName"/>
                                        <arg evaluator="xml" expression="$ctx:telco.correlationId"/>
                                        <arg evaluator="xml" expression="$ctx:telco.retryAfter"/>
                                        <arg evaluator="xml" expression="$ctx:telco.rateLimit"/>
                                    </args>
                                </payloadFactory>
                                <send>
                                    <endpoint name="RuntimePolicyAlertMIEndpoint">
                                        <http method="post" uri-template="http://wso2-mi:8290/internal/runtime-policy-alerts/v1/events">
                                            <timeout><duration>1500</duration><responseAction>discard</responseAction></timeout>
                                            <markForSuspension>
                                                <errorCodes>101504,101505</errorCodes>
                                                <retriesBeforeSuspension>1</retriesBeforeSuspension>
                                                <retryDelay>200</retryDelay>
                                            </markForSuspension>
                                            <suspendOnFailure>
                                                <errorCodes>101500,101501,101506,101507,101508</errorCodes>
                                                <initialDuration>5000</initialDuration>
                                                <progressionFactor>2.0</progressionFactor>
                                                <maximumDuration>30000</maximumDuration>
                                            </suspendOnFailure>
                                        </http>
                                    </endpoint>
                                </send>
                            </sequence>
                        </target>
                    </clone>

                    <property name="Retry-After" expression="$ctx:telco.retryAfter" scope="transport" type="STRING"/>
                    <property name="RateLimit-Limit" expression="$ctx:telco.rateLimit" scope="transport" type="STRING"/>
                    <property name="RateLimit-Remaining" value="0" scope="transport" type="STRING"/>
                    <property name="RateLimit-Reset" expression="$ctx:telco.rateLimitReset" scope="transport" type="STRING"/>
                    <property name="RateLimit-Policy" expression="$ctx:telco.policyName" scope="transport" type="STRING"/>
                    <property name="X-RateLimit-Limit" expression="$ctx:telco.rateLimit" scope="transport" type="STRING"/>
                    <property name="X-RateLimit-Remaining" value="0" scope="transport" type="STRING"/>
                    <property name="X-RateLimit-Reset" expression="$ctx:telco.rateLimitReset" scope="transport" type="STRING"/>
                    <property name="X-WSO2-Throttled-Out-Reason" expression="$ctx:telco.policyName" scope="transport" type="STRING"/>
                    <property name="X-Correlation-ID" expression="$ctx:telco.correlationId" scope="transport" type="STRING"/>

                    <payloadFactory media-type="json">
                        <format>{"type":"https://demo.telco.example/problems/rate-limit-exceeded","title":"Too Many Requests","status":429,"code":"900806","detail":"The request was rejected by a runtime telco business control.","policyName":"$1","partnerId":"$2","apiName":"$3","apiContext":"$4","apiVersion":"$5","applicationId":"$6","applicationName":"$7","correlationId":"$8","retryAfterSeconds":$9,"rateLimit":$10}</format>
                        <args>
                            <arg evaluator="xml" expression="$ctx:telco.policyName"/>
                            <arg evaluator="xml" expression="$ctx:telco.partnerId"/>
                            <arg evaluator="xml" expression="$ctx:telco.apiName"/>
                            <arg evaluator="xml" expression="$ctx:telco.apiContext"/>
                            <arg evaluator="xml" expression="$ctx:telco.apiVersion"/>
                            <arg evaluator="xml" expression="$ctx:telco.applicationId"/>
                            <arg evaluator="xml" expression="$ctx:telco.applicationName"/>
                            <arg evaluator="xml" expression="$ctx:telco.correlationId"/>
                            <arg evaluator="xml" expression="$ctx:telco.retryAfter"/>
                            <arg evaluator="xml" expression="$ctx:telco.rateLimit"/>
                        </args>
                    </payloadFactory>
                    <property name="HTTP_SC" value="429" scope="axis2" type="STRING"/>
                    <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <property name="ContentType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <property name="RESPONSE" value="true" scope="default" type="STRING"/>
                    <property name="NO_ENTITY_BODY" scope="axis2" action="remove"/>
                    <respond/>
                </then>
                <else>
                    <payloadFactory media-type="json">
                        <format>{"type":"https://demo.telco.example/problems/custom-policy-rate-limit","title":"Too Many Requests","status":429,"code":"900806","detail":"A custom APIM throttling policy rejected the request.","apiName":"$1","apiContext":"$2","apiVersion":"$3","applicationId":"$4","correlationId":"$5"}</format>
                        <args>
                            <arg evaluator="xml" expression="$ctx:telco.apiName"/>
                            <arg evaluator="xml" expression="$ctx:telco.apiContext"/>
                            <arg evaluator="xml" expression="$ctx:telco.apiVersion"/>
                            <arg evaluator="xml" expression="$ctx:telco.applicationId"/>
                            <arg evaluator="xml" expression="$ctx:telco.correlationId"/>
                        </args>
                    </payloadFactory>
                    <property name="HTTP_SC" value="429" scope="axis2" type="STRING"/>
                    <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <property name="ContentType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <property name="X-Correlation-ID" expression="$ctx:telco.correlationId" scope="transport" type="STRING"/>
                    <respond/>
                </else>
            </filter>
        </then>
        <else>
            <payloadFactory media-type="json">
                <format>{"type":"https://demo.telco.example/problems/apim-rate-limit","title":"Too Many Requests","status":429,"code":"$1","detail":"The request exceeded an API Manager throttling limit.","apiName":"$2","apiContext":"$3","apiVersion":"$4","applicationId":"$5","correlationId":"$6"}</format>
                <args>
                    <arg evaluator="xml" expression="$ctx:telco.errorCode"/>
                    <arg evaluator="xml" expression="$ctx:telco.apiName"/>
                    <arg evaluator="xml" expression="$ctx:telco.apiContext"/>
                    <arg evaluator="xml" expression="$ctx:telco.apiVersion"/>
                    <arg evaluator="xml" expression="$ctx:telco.applicationId"/>
                    <arg evaluator="xml" expression="$ctx:telco.correlationId"/>
                </args>
            </payloadFactory>
            <property name="HTTP_SC" value="429" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
            <property name="ContentType" value="application/problem+json" scope="axis2" type="STRING"/>
            <property name="X-Correlation-ID" expression="$ctx:telco.correlationId" scope="transport" type="STRING"/>
            <respond/>
        </else>
    </filter>
</sequence>
XML

log "Installing the MI alert API and resilient Kafka endpoint"
write_file services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<endpoint xmlns="http://ws.apache.org/ns/synapse" name="RuntimePolicyKafkaEndpoint">
    <!-- A failover group with three identical resilient leaves provides a bounded
         primary attempt plus two retries without custom Java/Node/Python code. -->
    <failover>
        <endpoint name="RuntimePolicyKafkaPrimary">
            <http method="post" uri-template="$SYSTEM:runtime_policy_kafka_url">
                <timeout><duration>1500</duration><responseAction>fault</responseAction></timeout>
                <markForSuspension>
                    <errorCodes>101504,101505</errorCodes>
                    <retriesBeforeSuspension>0</retriesBeforeSuspension>
                    <retryDelay>0</retryDelay>
                </markForSuspension>
                <suspendOnFailure>
                    <errorCodes>101500,101501,101506,101507,101508</errorCodes>
                    <initialDuration>5000</initialDuration>
                    <progressionFactor>2.0</progressionFactor>
                    <maximumDuration>30000</maximumDuration>
                </suspendOnFailure>
            </http>
        </endpoint>
        <endpoint name="RuntimePolicyKafkaRetryOne">
            <http method="post" uri-template="$SYSTEM:runtime_policy_kafka_url">
                <timeout><duration>1500</duration><responseAction>fault</responseAction></timeout>
                <markForSuspension>
                    <errorCodes>101504,101505</errorCodes>
                    <retriesBeforeSuspension>0</retriesBeforeSuspension>
                    <retryDelay>250</retryDelay>
                </markForSuspension>
                <suspendOnFailure>
                    <errorCodes>101500,101501,101506,101507,101508</errorCodes>
                    <initialDuration>5000</initialDuration>
                    <progressionFactor>2.0</progressionFactor>
                    <maximumDuration>30000</maximumDuration>
                </suspendOnFailure>
            </http>
        </endpoint>
        <endpoint name="RuntimePolicyKafkaRetryTwo">
            <http method="post" uri-template="$SYSTEM:runtime_policy_kafka_url">
                <timeout><duration>1500</duration><responseAction>fault</responseAction></timeout>
                <markForSuspension>
                    <errorCodes>101504,101505</errorCodes>
                    <retriesBeforeSuspension>0</retriesBeforeSuspension>
                    <retryDelay>250</retryDelay>
                </markForSuspension>
                <suspendOnFailure>
                    <errorCodes>101500,101501,101506,101507,101508</errorCodes>
                    <initialDuration>5000</initialDuration>
                    <progressionFactor>2.0</progressionFactor>
                    <maximumDuration>30000</maximumDuration>
                </suspendOnFailure>
            </http>
        </endpoint>
    </failover>
</endpoint>
XML

write_file services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<api xmlns="http://ws.apache.org/ns/synapse" name="RuntimePolicyAlertAPI" context="/internal/runtime-policy-alerts/v1">
    <resource methods="GET" uri-template="/health">
        <inSequence>
            <payloadFactory media-type="json">
                <format>{"status":"UP","service":"RuntimePolicyAlertAPI","runtime":"WSO2 Integrator: MI","version":"1.0.0"}</format>
                <args/>
            </payloadFactory>
            <property name="HTTP_SC" value="200" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <respond/>
        </inSequence>
    </resource>
    <resource methods="POST" uri-template="/events">
        <inSequence>
            <property name="runtime.correlationId" expression="json-eval($.correlationId)" type="STRING"/>
            <property name="runtime.partnerId" expression="json-eval($.partnerId)" type="STRING"/>
            <property name="runtime.apiContext" expression="json-eval($.apiContext)" type="STRING"/>
            <property name="runtime.apiName" expression="json-eval($.apiName)" type="STRING"/>
            <property name="runtime.applicationId" expression="json-eval($.applicationId)" type="STRING"/>
            <property name="runtime.policyName" expression="json-eval($.policyName)" type="STRING"/>
            <property name="runtime.originalPayload" expression="json-eval($)" type="STRING"/>

            <filter xpath="not(string-length(normalize-space($ctx:runtime.correlationId)) &gt; 0) or not(string-length(normalize-space($ctx:runtime.partnerId)) &gt; 0) or not(string-length(normalize-space($ctx:runtime.apiContext)) &gt; 0) or not(string-length(normalize-space($ctx:runtime.applicationId)) &gt; 0) or not(string-length(normalize-space($ctx:runtime.policyName)) &gt; 0)">
                <then>
                    <payloadFactory media-type="json">
                        <format>{"type":"https://demo.telco.example/problems/invalid-runtime-policy-alert","title":"Invalid runtime policy alert","status":400,"detail":"policyName, partnerId, apiContext, applicationId and correlationId are required.","correlationId":"$1"}</format>
                        <args><arg evaluator="xml" expression="$ctx:runtime.correlationId"/></args>
                    </payloadFactory>
                    <property name="HTTP_SC" value="400" scope="axis2" type="STRING"/>
                    <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
                    <respond/>
                </then>
            </filter>

            <property name="X-Correlation-ID" expression="$ctx:runtime.correlationId" scope="transport" type="STRING"/>
            <property name="Content-Type" value="application/json" scope="transport" type="STRING"/>
            <property name="Accept" value="application/json" scope="transport" type="STRING"/>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
            <call>
                <endpoint key="RuntimePolicyKafkaEndpoint"/>
            </call>

            <payloadFactory media-type="json">
                <format>{"accepted":true,"status":"PUBLISHED_TO_KAFKA","topic":"telco.runtime.policy.alerts","policyName":"$1","partnerId":"$2","apiName":"$3","apiContext":"$4","applicationId":"$5","correlationId":"$6"}</format>
                <args>
                    <arg evaluator="xml" expression="$ctx:runtime.policyName"/>
                    <arg evaluator="xml" expression="$ctx:runtime.partnerId"/>
                    <arg evaluator="xml" expression="$ctx:runtime.apiName"/>
                    <arg evaluator="xml" expression="$ctx:runtime.apiContext"/>
                    <arg evaluator="xml" expression="$ctx:runtime.applicationId"/>
                    <arg evaluator="xml" expression="$ctx:runtime.correlationId"/>
                </args>
            </payloadFactory>
            <property name="HTTP_SC" value="202" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <property name="X-Correlation-ID" expression="$ctx:runtime.correlationId" scope="transport" type="STRING"/>
            <respond/>
        </inSequence>
        <faultSequence>
            <payloadFactory media-type="json">
                <format>{"type":"https://demo.telco.example/problems/runtime-policy-alert-delivery","title":"Runtime policy alert delivery failed","status":503,"detail":"The Kafka alert endpoint was unavailable or suspended after bounded retries.","policyName":"$1","partnerId":"$2","apiContext":"$3","applicationId":"$4","correlationId":"$5"}</format>
                <args>
                    <arg evaluator="xml" expression="$ctx:runtime.policyName"/>
                    <arg evaluator="xml" expression="$ctx:runtime.partnerId"/>
                    <arg evaluator="xml" expression="$ctx:runtime.apiContext"/>
                    <arg evaluator="xml" expression="$ctx:runtime.applicationId"/>
                    <arg evaluator="xml" expression="$ctx:runtime.correlationId"/>
                </args>
            </payloadFactory>
            <property name="HTTP_SC" value="503" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
            <property name="X-Correlation-ID" expression="$ctx:runtime.correlationId" scope="transport" type="STRING"/>
            <respond/>
        </faultSequence>
    </resource>
</api>
XML

log "Updating the public NetworkSliceAPI contract with the QoD operation"
for oas in contracts/openapi/network-slice.openapi.yaml artifacts/contracts/openapi/network-slice.openapi.yaml; do
  write_file "$oas" <<'YAML'
openapi: 3.0.3
info:
  title: NetworkSliceAPI
  version: 1.0.0
  description: >-
    5G network slice catalog, reservation, cell SLA status and Quality-on-Demand
    session API for premium network monetization. Runtime QoD burst assurance is
    enforced by TelcoSiddhiQoDAssuranceBurstPolicy.
servers:
  - url: http://telco-backend:8081
x-wso2-basePath: /network-slice/v1
x-wso2-production-endpoints:
  urls:
    - http://telco-backend:8081
x-wso2-throttling-tier: 10kPerMin
x-telco-owner: Network Platform Engineering
x-telco-country-scope: [MX, BR, CO, CL]
x-telco-data-classification: Internal-Network
x-telco-monetization-model: Network Premium plan; reserved capacity + event metering
x-telco-api-product: Network Monetization Pack
x-telco-privacy-review: approved-no-pii
x-telco-healthcheck:
  method: GET
  path: /health
security:
  - OAuth2: [network.slice.read, network.slice.reserve]
tags:
  - name: Slices
  - name: Reservations
  - name: Quality on Demand
  - name: Cell Status
paths:
  /api/v1/network/slices:
    get:
      tags: [Slices]
      operationId: listNetworkSlices
      summary: List available and reserved 5G network slices
      responses:
        '200':
          description: Slice catalog
          content:
            application/json:
              schema:
                type: object
                properties:
                  slices:
                    type: array
                    items:
                      $ref: '#/components/schemas/NetworkSlice'
  /api/v1/network/slices/reservations:
    post:
      tags: [Reservations]
      operationId: reserveNetworkSlice
      summary: Reserve a network slice for a partner workload
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/SliceReservationRequest'
      responses:
        '201':
          description: Reservation accepted
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/SliceReservationResponse'
  /api/v1/network/qod/sessions:
    post:
      tags: [Quality on Demand]
      operationId: createQualityOnDemandSession
      summary: Request an assured Quality-on-Demand session
      description: >-
        Creates a short-lived QoD session for the requested device and area. A
        runtime Siddhi assurance policy protects shared network capacity. During
        the demo, nine requests in a five-second time batch trigger HTTP 429 on
        subsequent requests until the policy window clears.
      security:
        - OAuth2: [network.qod.request]
      parameters:
        - name: X-Partner-Id
          in: header
          required: true
          description: Stable partner identity included in runtime control events.
          schema:
            type: string
        - name: X-Correlation-ID
          in: header
          required: true
          description: End-to-end correlation identifier returned in errors and alerts.
          schema:
            type: string
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/QoDSessionRequest'
            example:
              device:
                phoneNumber: '+525512340001'
              area:
                type: CELL_ID
                value: MX-MEX-CELL-001
              profile: QOD_GOLD
              durationSeconds: 120
              maxLatencyMs: 20
              minThroughputMbps: 100
      responses:
        '201':
          description: QoD session accepted
          headers:
            X-Correlation-ID:
              schema: { type: string }
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/QoDSessionResponse'
        '400':
          description: Invalid QoD request
          content:
            application/problem+json:
              schema:
                $ref: '#/components/schemas/Problem'
        '429':
          description: Runtime QoD assurance burst policy exceeded
          headers:
            Retry-After:
              description: Seconds before the caller should retry.
              schema: { type: integer, example: 5 }
            RateLimit-Limit:
              schema: { type: integer, example: 9 }
            RateLimit-Remaining:
              schema: { type: integer, example: 0 }
            RateLimit-Reset:
              schema: { type: integer, example: 5 }
            RateLimit-Policy:
              schema: { type: string, example: TelcoSiddhiQoDAssuranceBurstPolicy }
            X-Correlation-ID:
              schema: { type: string }
          content:
            application/problem+json:
              schema:
                $ref: '#/components/schemas/Problem'
  /api/v1/network/cells/{cellId}/status:
    get:
      tags: [Cell Status]
      operationId: getCellStatus
      summary: Retrieve current radio cell status and utilization
      parameters:
        - name: cellId
          in: path
          required: true
          schema: { type: string }
      responses:
        '200':
          description: Cell status
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CellStatus'
components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        clientCredentials:
          tokenUrl: https://identity.telco.example/oauth2/token
          scopes:
            network.slice.read: Read slice catalog and cell status
            network.slice.reserve: Reserve network slices
            network.qod.request: Create assured Quality-on-Demand sessions
  schemas:
    NetworkSlice:
      type: object
      properties:
        id: { type: string }
        status: { type: string, enum: [AVAILABLE, RESERVED, DEGRADED] }
        maxLatencyMs: { type: integer }
        maxThroughputMbps: { type: integer }
        monetizationPlan: { type: string }
    SliceReservationRequest:
      type: object
      required: [sliceId, country, partnerId, durationMinutes]
      properties:
        sliceId: { type: string }
        country: { type: string }
        partnerId: { type: string }
        durationMinutes: { type: integer }
        maxLatencyMs: { type: integer }
    SliceReservationResponse:
      type: object
      properties:
        reservationId: { type: string }
        status: { type: string }
        activationEtaSeconds: { type: integer }
        chargePreviewUsd: { type: number }
    QoDSessionRequest:
      type: object
      required: [device, area, profile, durationSeconds]
      properties:
        device:
          type: object
          required: [phoneNumber]
          properties:
            phoneNumber: { type: string }
        area:
          type: object
          required: [type, value]
          properties:
            type: { type: string, enum: [CELL_ID, CIRCLE, POLYGON] }
            value: { type: string }
        profile: { type: string, enum: [QOD_BRONZE, QOD_SILVER, QOD_GOLD] }
        durationSeconds: { type: integer, minimum: 30, maximum: 3600 }
        maxLatencyMs: { type: integer, minimum: 1 }
        minThroughputMbps: { type: integer, minimum: 1 }
    QoDSessionResponse:
      type: object
      properties:
        qodSessionId: { type: string }
        status: { type: string, enum: [REQUESTED, ACTIVE, REJECTED] }
        partnerId: { type: string }
        correlationId: { type: string }
        profile: { type: string }
        device: { type: object, additionalProperties: true }
        area: { type: object, additionalProperties: true }
        durationSeconds: { type: integer }
        maxLatencyMs: { type: integer }
        minThroughputMbps: { type: integer }
        activationEtaSeconds: { type: integer }
        chargePreviewUsd: { type: number }
        createdAt: { type: string, format: date-time }
    CellStatus:
      type: object
      properties:
        cellId: { type: string }
        country: { type: string }
        status: { type: string }
        utilizationPct: { type: integer }
        avgLatencyMs: { type: integer }
        activeSessions: { type: integer }
    Problem:
      type: object
      required: [title, status, correlationId]
      properties:
        type: { type: string }
        title: { type: string }
        status: { type: integer }
        code: { type: string }
        detail: { type: string }
        policyName: { type: string }
        partnerId: { type: string }
        apiName: { type: string }
        apiContext: { type: string }
        apiVersion: { type: string }
        applicationId: { type: string }
        applicationName: { type: string }
        correlationId: { type: string }
        retryAfterSeconds: { type: integer }
        rateLimit: { type: integer }
YAML
done

log "Adding the QoD backend simulation route and the Kafka alert topic"
python3 - <<'PY'
from pathlib import Path

server = Path('services/telco-backend/src/server.js')
text = server.read_text(encoding='utf-8')
marker = '// BEGIN SIDDHI RUNTIME QOD DEMO ROUTE'
if marker not in text:
    anchor = '// BEGIN OPEN GATEWAY / CAMARA DEMO ROUTES'
    if anchor not in text:
        raise SystemExit(f'Cannot patch {server}: expected Open Gateway marker not found')
    block = r'''// BEGIN SIDDHI RUNTIME QOD DEMO ROUTE
app.post('/api/v1/network/qod/sessions', (req, res) => {
  const partnerId = req.headers['x-partner-id'] || req.body?.partnerId || 'enterprise-qod-demo';
  const correlationId = req.headers['x-correlation-id'] || `corr-qod-${Date.now()}`;
  const durationSeconds = Math.max(30, Math.min(Number(req.body?.durationSeconds || 120), 3600));
  const maxLatencyMs = Math.max(1, Number(req.body?.maxLatencyMs || 20));
  const minThroughputMbps = Math.max(1, Number(req.body?.minThroughputMbps || 100));
  const profile = req.body?.profile || 'QOD_GOLD';
  const profileMultiplier = profile === 'QOD_GOLD' ? 1.8 : profile === 'QOD_SILVER' ? 1.25 : 1;
  const chargePreviewUsd = Number((durationSeconds / 60 * profileMultiplier * 0.35).toFixed(2));

  res.status(201).json({
    qodSessionId: `qod-${Date.now()}-${Math.floor(Math.random() * 10000)}`,
    status: 'REQUESTED',
    partnerId,
    correlationId,
    profile,
    device: req.body?.device || { phoneNumber: '+525512340001' },
    area: req.body?.area || { type: 'CELL_ID', value: 'MX-MEX-CELL-001' },
    durationSeconds,
    maxLatencyMs,
    minThroughputMbps,
    activationEtaSeconds: 3,
    chargePreviewUsd,
    createdAt: new Date().toISOString()
  });
});
// END SIDDHI RUNTIME QOD DEMO ROUTE

'''
    text = text.replace(anchor, block + anchor, 1)
    server.write_text(text, encoding='utf-8')

kafka = Path('services/telco-backend/src/kafka-broker.js')
text = kafka.read_text(encoding='utf-8')
if "'telco.runtime.policy.alerts'" not in text:
    old = "  'telco.partner.settlement.events'\n];"
    new = "  'telco.partner.settlement.events',\n  'telco.runtime.policy.alerts'\n];"
    if old not in text:
        raise SystemExit(f'Cannot patch {kafka}: TOPICS anchor not found')
    text = text.replace(old, new, 1)
    kafka.write_text(text, encoding='utf-8')
PY


log "Patching the APIM image, MI configuration and bootstrap order"
python3 - <<'PY'
import json
from pathlib import Path

# APIM image: copy the custom throttle sequence before dropping privileges.
p = Path('services/wso2-apim/Dockerfile')
text = p.read_text(encoding='utf-8')
marker = '# BEGIN TELCO SIDDHI RUNTIME ENFORCEMENT'
if marker not in text:
    anchor = 'USER wso2carbon'
    if anchor not in text:
        raise SystemExit(f'Cannot patch {p}: final USER anchor not found')
    block = '''# BEGIN TELCO SIDDHI RUNTIME ENFORCEMENT
RUN mkdir -p /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences
COPY services/wso2-apim/sequences/_throttle_out_handler_.xml /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml
RUN chown wso2carbon /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml \
 && chmod 0644 /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml
# END TELCO SIDDHI RUNTIME ENFORCEMENT

'''
    text = text.replace(anchor, block + anchor, 1)
    p.write_text(text, encoding='utf-8')

# MI ${configs.*} default, overridable with RUNTIME_POLICY_KAFKA_URL.
p = Path('services/wso2-mi/conf/file.properties')
text = p.read_text(encoding='utf-8').rstrip() + '\n'
if 'runtime_policy_kafka_url=' not in text:
    text += 'runtime_policy_kafka_url=http://telco-backend:8081/api/v1/kafka/topics/telco.runtime.policy.alerts/events\n'
p.write_text(text, encoding='utf-8')

# Bootstrap module order.
p = Path('services/apim-bootstrapper/package.json')
data = json.loads(p.read_text(encoding='utf-8'))
steps = [part.strip() for part in data['scripts']['start'].split('&&')]
new_step = 'node src/siddhi-runtime-enforcement-setup.js'
# Always position the runtime definition update before API Product reconciliation.
# Removing/reinserting also corrects an earlier installer run without duplicating it.
steps = [step for step in steps if step != new_step]
try:
    idx = steps.index('node src/api-product-bundles-setup.js')
except ValueError:
    try:
        idx = steps.index('node src/developer-experience-setup.js')
    except ValueError:
        idx = len(steps)
steps.insert(idx, new_step)
data['scripts']['start'] = ' && '.join(steps)
p.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY

log "Extending the idempotent Service Catalog registration"
python3 - <<'PY'
from pathlib import Path
p = Path('scripts/register-mi-service-catalog.sh')
text = p.read_text(encoding='utf-8')
if '"name": "RuntimePolicyAlertAPI"' not in text:
    anchor = '\n]\n\ndef operation'
    if anchor not in text:
        anchor = '\n]\ndef operation'
    if anchor not in text:
        raise SystemExit(f'Cannot patch {p}: Python services-list anchor not found')
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
    text = text.replace(anchor, service + anchor, 1)

if '  RuntimePolicyAlertAPI\n' not in text:
    expected_anchor = '  OssRiskAdapterAPI\n)'
    if expected_anchor not in text:
        raise SystemExit(f'Cannot patch {p}: EXPECTED_SERVICES anchor not found')
    text = text.replace(expected_anchor, '  OssRiskAdapterAPI\n  RuntimePolicyAlertAPI\n)', 1)
text = text.replace('All five MI services are registered.', 'All six MI services are registered.')
p.write_text(text, encoding='utf-8')
PY

log "Adding health checks and startup ordering overlay"
write_file docker-compose.siddhi-runtime.yml <<'YAML'
services:
  redpanda:
    healthcheck:
      test: ["CMD-SHELL", "rpk cluster health | grep -E 'Healthy:.+true' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 10s

  telco-backend:
    depends_on:
      redpanda:
        condition: service_healthy
    healthcheck:
      test:
        - CMD
        - node
        - -e
        - >-
          const http=require('http');const r=http.get('http://127.0.0.1:8081/health',res=>{res.resume();process.exit(res.statusCode===200?0:1)});r.on('error',()=>process.exit(1));r.setTimeout(3000,()=>{r.destroy();process.exit(1)})
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 10s

  wso2-apim:
    healthcheck:
      test: ["CMD-SHELL", "curl -ksSf https://127.0.0.1:9443/services/Version >/dev/null || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 60
      start_period: 90s

  wso2-mi:
    environment:
      runtime_policy_kafka_url: http://telco-backend:8081/api/v1/kafka/topics/telco.runtime.policy.alerts/events
    depends_on:
      wso2-apim:
        condition: service_healthy
      telco-backend:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8290/internal/runtime-policy-alerts/v1/health >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 40
      start_period: 90s

  apim-bootstrapper:
    depends_on:
      wso2-apim:
        condition: service_healthy
      wso2-mi:
        condition: service_healthy
      telco-backend:
        condition: service_healthy
      redpanda:
        condition: service_healthy
YAML

log "Adding idempotent Developer Portal documentation bootstrap"
write_file services/apim-bootstrapper/src/siddhi-runtime-enforcement-setup.js <<'JS'
'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, FormData, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const STATE_FILE = process.env.APIM_SIDDHI_RUNTIME_STATE_FILE || '/workspace/state/siddhi-runtime-enforcement.json';
const CONTRACT_ROOT = process.env.APIM_CONTRACT_ROOT || '/workspace/contracts/openapi';
const DOCUMENT_NAME = '10 - Runtime Business Controls';

const TARGETS = {
  OpenGatewaySimSwapRiskAPI: {
    contract: 'open-gateway-sim-swap-risk.openapi.yaml',
    swaggerMarker: 'TelcoSiddhiSimSwapFraudFairUsePolicy',
    policy: 'TelcoSiddhiSimSwapFraudFairUsePolicy',
    context: '/open-gateway/sim-swap/v1',
    threshold: 6,
    window: '15 seconds',
    retryAfter: 15,
    scope: 'opengateway_sim_swap',
    product: 'OpenGatewayFraudDefenseProduct',
    plans: ['TelcoFreeTrial', 'TelcoOpenGatewayTrustStarter', 'TelcoOpenGatewayTrustPremium'],
    sample: `curl -k -i \\
  -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
  -H "X-Partner-Id: digital-bank-demo" \\
  -H "X-Correlation-ID: sim-swap-demo-001" \\
  "https://localhost:8243/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168"`
  },
  NetworkSliceAPI: {
    contract: 'network-slice.openapi.yaml',
    swaggerMarker: 'createQualityOnDemandSession',
    policy: 'TelcoSiddhiQoDAssuranceBurstPolicy',
    context: '/network-slice/v1',
    threshold: 9,
    window: '5 seconds',
    retryAfter: 5,
    scope: 'network.qod.request',
    product: 'FiveGNetworkMonetizationProduct',
    plans: ['TelcoPartnerStandard', 'TelcoPartnerPremium'],
    sample: `curl -k -i -X POST \\
  -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -H "X-Partner-Id: enterprise-qod-demo" \\
  -H "X-Correlation-ID: qod-demo-001" \\
  -d '{"device":{"phoneNumber":"+525512340001"},"area":{"type":"CELL_ID","value":"MX-MEX-CELL-001"},"profile":"QOD_GOLD","durationSeconds":120,"maxLatencyMs":20,"minThroughputMbps":100}' \\
  "https://localhost:8243/network-slice/v1/1.0.0/api/v1/network/qod/sessions"`
  }
};

class HttpError extends Error {
  constructor(method, url, status, data) {
    super(`${method} ${url} -> HTTP ${status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
    this.status = status;
    this.data = data;
  }
}

function log(message) {
  console.log(`[Siddhi Runtime Enforcement] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

async function request(url, { method = 'GET', bearer, basic, json, body, headers = {}, ok = [200, 201, 202, 204] } = {}) {
  const requestHeaders = { ...headers };
  if (bearer) requestHeaders.Authorization = `Bearer ${bearer}`;
  if (basic) requestHeaders.Authorization = `Basic ${Buffer.from(basic).toString('base64')}`;
  if (json !== undefined) {
    requestHeaders['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  }
  const response = await fetch(url, { method, headers: requestHeaders, body, dispatcher });
  const text = await response.text();
  let data = text;
  try { data = text ? JSON.parse(text) : null; } catch { /* keep text */ }
  if (!ok.includes(response.status)) throw new HttpError(method, url, response.status, data);
  return data;
}

async function waitForApim() {
  for (let attempt = 1; attempt <= 90; attempt += 1) {
    try {
      const response = await fetch(`${APIM_URL}/services/Version`, { dispatcher });
      if (response.ok) return;
    } catch { /* APIM is starting */ }
    await sleep(5000);
  }
  throw new Error(`APIM did not become reachable at ${APIM_URL}`);
}

async function accessToken(clientId, clientSecret) {
  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set('scope', [
    'apim:api_view',
    'apim:api_metadata_view',
    'apim:api_create',
    'apim:api_publish',
    'apim:document_create',
    'apim:document_manage',
    'apim:document_update'
  ].join(' '));
  const token = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${clientId}:${clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
    ok: [200]
  });
  if (!token.access_token) throw new Error('Publisher token response did not contain access_token');
  return token.access_token;
}

async function publisherToken(state) {
  const saved = state.oauth || {};
  if (saved.clientId && saved.clientSecret) {
    try {
      return { token: await accessToken(saved.clientId, saved.clientSecret), oauth: saved };
    } catch (error) {
      log(`Stored OAuth client is unusable; registering a replacement (${error.message})`);
    }
  }

  const dcr = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-siddhi-runtime-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    },
    ok: [200, 201]
  });
  const oauth = { clientId: dcr.clientId, clientSecret: dcr.clientSecret };
  if (!oauth.clientId || !oauth.clientSecret) throw new Error('Dynamic client registration did not return credentials');
  state.oauth = oauth;
  saveState(state);
  return { token: await accessToken(oauth.clientId, oauth.clientSecret), oauth };
}

function contractText(cfg) {
  const candidate = path.join(CONTRACT_ROOT, cfg.contract);
  if (!fs.existsSync(candidate)) throw new Error(`Runtime API contract is missing: ${candidate}`);
  return fs.readFileSync(candidate, 'utf8');
}

function textValue(value) {
  return typeof value === 'string' ? value : JSON.stringify(value);
}

function deploymentList(value) {
  return Array.isArray(value) ? value : (value?.list || value?.data || value?.deployments || []);
}

function currentDeploymentEnvironments(deployments) {
  const result = [];
  const seen = new Set();
  for (const item of deploymentList(deployments)) {
    const info = item.deploymentInfo || item;
    const name = info.name || info.environment || item.name || item.environment;
    if (!name || seen.has(name)) continue;
    seen.add(name);
    result.push({
      name,
      vhost: info.vhost || item.vhost || 'localhost',
      displayOnDevportal: info.displayOnDevportal ?? item.displayOnDevportal ?? true
    });
  }
  return result.length ? result : [{ name: 'Default', vhost: 'localhost', displayOnDevportal: true }];
}

function revisionId(value) {
  return value?.id || value?.revisionId || value?.revisionUuid || value?.uuid;
}

async function createRevision(token, api, deployments) {
  const base = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/revisions`;
  const create = () => request(base, {
    method: 'POST',
    bearer: token,
    json: { description: 'Runtime Siddhi controls: live OpenAPI, QoD resource and normalized 429 contract.' },
    ok: [200, 201]
  });
  try {
    return await create();
  } catch (error) {
    if (!(error instanceof HttpError) || error.status !== 409) throw error;
    const revisions = await request(`${base}?limit=100`, { bearer: token });
    const deployed = new Set(deploymentList(deployments).map(revisionId).filter(Boolean));
    const candidate = deploymentList(revisions).find(item => {
      const id = revisionId(item);
      return id && !deployed.has(id);
    });
    const removable = revisionId(candidate);
    if (!removable) throw new Error(`Cannot create a revision for ${api.name}: APIM revision limit reached and every revision is deployed.`);
    await request(`${base}/${encodeURIComponent(removable)}`, { method: 'DELETE', bearer: token, ok: [200, 204] });
    log(`Deleted undeployed revision ${removable} for ${api.name}`);
    return create();
  }
}

async function ensureLiveDefinition(token, api, cfg) {
  const swaggerUrl = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/swagger`;
  const current = await request(swaggerUrl, { bearer: token });
  if (textValue(current).includes(cfg.swaggerMarker)) {
    log(`${api.name}:1.0.0 already has the runtime OpenAPI definition`);
    return { changed: false };
  }

  const form = new FormData();
  form.set('apiDefinition', contractText(cfg));
  await request(swaggerUrl, { method: 'PUT', bearer: token, body: form, ok: [200] });
  log(`Updated live OpenAPI definition for ${api.name}:1.0.0`);

  const deployments = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deployments`, { bearer: token });
  const revision = await createRevision(token, api, deployments);
  const id = revisionId(revision);
  if (!id) throw new Error(`Revision ID missing after updating ${api.name}:1.0.0`);
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deploy-revision?revisionId=${encodeURIComponent(id)}`, {
    method: 'POST',
    bearer: token,
    json: currentDeploymentEnvironments(deployments),
    ok: [200, 201]
  });
  log(`Created and deployed revision ${id} for ${api.name}:1.0.0`);
  return { changed: true, revisionId: id };
}

function documentContent(api, cfg) {
  return `# Runtime Business Controls

## Enforcement point

This API is protected in the **WSO2 API Manager 4.7 runtime** by the custom Siddhi policy \`${cfg.policy}\`. The policy is evaluated by the APIM Traffic Manager using the real API context/version${api.name === 'OpenGatewaySimSwapRiskAPI' ? ' and consuming application identifier' : ''}; it is not only an uploaded Admin Portal artifact.

## Demonstration limit

- API context: \`${cfg.context}\`
- API version: \`${api.version}\`
- Demo threshold: **${cfg.threshold} requests per ${cfg.window} Siddhi time batch**
- OAuth scope: \`${cfg.scope}\`
- API Product: \`${cfg.product}\`
- Commercial/subscription policies: ${cfg.plans.map(value => `\`${value}\``).join(', ')}

The threshold is intentionally low for a deterministic demonstration. Production values must be derived from contracted partner entitlement, backend capacity, SLA and fraud/network risk appetite.

## 429 response contract

When the policy is active, APIM returns \`429 Too Many Requests\` with:

- \`Retry-After: ${cfg.retryAfter}\`
- \`RateLimit-Limit\`, \`RateLimit-Remaining\`, \`RateLimit-Reset\`
- \`RateLimit-Policy: ${cfg.policy}\`
- compatibility \`X-RateLimit-*\` headers
- \`X-Correlation-ID\`
- an \`application/problem+json\` body containing the partner, API, application, policy and correlation identifiers

Consumers must honor \`Retry-After\`, use bounded exponential backoff with jitter, and must not evade fair use by creating duplicate applications.

## Observable alert

For custom-policy error code \`900806\`, the APIM throttle-out sequence asynchronously calls the MI-managed \`RuntimePolicyAlertAPI\`. MI validates the event, preserves the correlation identifier, and publishes it to Kafka topic \`telco.runtime.policy.alerts\` through a timeout/retry/suspension-protected endpoint. Alert delivery is a non-blocking partial-response path: an alert failure cannot replace the client-facing 429.

Every alert includes:

- \`policyName\`
- \`partnerId\`
- \`apiName\`, \`apiContext\`, \`apiVersion\`
- \`applicationId\`, \`applicationName\`
- \`correlationId\`
- HTTP status, APIM error code, limit and retry interval

## Consent and privacy

The rate-control event contains operational identifiers, not SIM, location or request payload data. The consuming application remains responsible for purpose-bound consent/legal basis for the underlying API operation and for avoiding personal data in partner/correlation headers.

## Sandbox request

\`\`\`bash
export ACCESS_TOKEN='<application access token with ${cfg.scope}>'
${cfg.sample}
\`\`\`

Repeat the request rapidly using a unique correlation ID for each policy demonstration. The repository verification script performs the complete burst, 429/header/body validation and Kafka event lookup automatically.

## Postman and SDKs

Import \`artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json\` for the runtime examples. SDKs generated from the Developer Portal use the updated OpenAPI definition; consumers must add retry/backoff handling for the documented 429 response.

## SLA and support evidence

For support, provide UTC timestamp, API name/version, application name, partner ID and correlation ID. Do not include access tokens or subscriber payloads. The demo limit is non-contractual; production policy changes require API product owner and network/fraud operations approval.
`;
}

async function upsertDocument(token, api, content) {
  const base = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/documents`;
  const docs = await request(`${base}?limit=100`, { bearer: token });
  const existing = (docs.list || []).find(item => item.name === DOCUMENT_NAME);
  const metadata = {
    name: DOCUMENT_NAME,
    summary: 'Runtime Siddhi fair-use/assurance limits, 429 contract, Kafka alert evidence and consumer guidance.',
    type: 'HOWTO',
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL'
  };
  let doc;
  if (existing) {
    doc = await request(`${base}/${existing.documentId || existing.id}`, {
      method: 'PUT', bearer: token, json: metadata, ok: [200]
    });
  } else {
    doc = await request(base, { method: 'POST', bearer: token, json: metadata, ok: [201] });
  }
  const documentId = doc.documentId || doc.id || existing?.documentId || existing?.id;
  if (!documentId) throw new Error(`Document ID missing for ${api.name}`);
  const form = new FormData();
  form.set('inlineContent', content);
  await request(`${base}/${documentId}/content`, {
    method: 'POST', bearer: token, body: form, ok: [200, 201]
  });
  return documentId;
}

async function main() {
  await waitForApim();
  const state = loadState();
  const auth = await publisherToken(state);
  state.oauth = auth.oauth;
  const response = await request(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, { bearer: auth.token });
  const apis = response.list || [];
  state.generatedAt = new Date().toISOString();
  state.documentName = DOCUMENT_NAME;
  state.apis = [];

  for (const [name, cfg] of Object.entries(TARGETS)) {
    const api = apis.find(item => item.name === name && item.version === '1.0.0');
    if (!api) throw new Error(`Required API not found: ${name}:1.0.0`);
    const lifecycle = api.lifeCycleStatus || api.state;
    if (lifecycle && lifecycle !== 'PUBLISHED') {
      throw new Error(`${name}:1.0.0 is not PUBLISHED (state=${lifecycle})`);
    }
    const definition = await ensureLiveDefinition(auth.token, api, cfg);
    const documentId = await upsertDocument(auth.token, api, documentContent(api, cfg));
    state.apis.push({
      name,
      version: api.version,
      apiId: api.id,
      documentId,
      policy: cfg.policy,
      definitionChanged: definition.changed,
      revisionId: definition.revisionId || null
    });
    log(`Upserted ${DOCUMENT_NAME} for ${name}:1.0.0`);
  }

  saveState(state);
  log(`State written to ${STATE_FILE}`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
JS

log "Updating the SIM Swap consumer contract with the runtime 429 contract"
for oas in contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml artifacts/contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml; do
  write_file "$oas" <<'YAML'
openapi: 3.0.3
info:
  title: OpenGatewaySimSwapRiskAPI
  version: 1.0.0
  description: >-
    Open Gateway / CAMARA-style SIM Swap risk API for fraud prevention,
    digital banking, lending, wallet recovery and account-takeover protection.
    Runtime partner/application fair use is enforced by
    TelcoSiddhiSimSwapFraudFairUsePolicy.
  contact:
    name: Open Gateway Product Office
    email: open-gateway-product@example.com
servers:
  - url: /
tags:
  - name: SIM Swap
    description: Open Gateway trust signal for recent SIM changes.
x-wso2-basePath: /open-gateway/sim-swap/v1
x-telco-api-product: Open Gateway Fraud Prevention Pack
x-telco-domain: Open Gateway / Fraud Prevention
x-telco-owner: Open Gateway Product Office
x-telco-country-scope: [MX, BR, CO, CL]
x-telco-monetization-model: PAY_PER_RISK_CHECK
x-telco-health-path: /health
x-camara-style-capability: SIM Swap
paths:
  /api/v1/open-gateway/sim-swap/{msisdn}/risk:
    get:
      tags: [SIM Swap]
      operationId: getSimSwapRisk
      summary: Get recent SIM swap risk for an MSISDN
      description: >-
        Returns a fraud risk signal based on recent SIM change activity. Designed
        for checkout, high-value transfer, device binding and account recovery
        flows. Six requests for one APIM application/context/version within the
        15-second demo time batch activate the runtime fair-use control.
      security:
        - OAuth2: [opengateway_sim_swap]
      parameters:
        - name: msisdn
          in: path
          required: true
          schema:
            type: string
            example: '+525512340001'
        - name: lookbackHours
          in: query
          required: false
          schema:
            type: integer
            default: 168
          description: Lookback window in hours.
        - name: X-Partner-Id
          in: header
          required: true
          description: Stable partner identity included in runtime policy alerts.
          schema: { type: string, example: digital-bank-demo }
        - name: X-Correlation-ID
          in: header
          required: true
          description: End-to-end correlation identifier.
          schema: { type: string, example: sim-swap-demo-001 }
      responses:
        '200':
          description: SIM swap risk result.
          headers:
            X-Correlation-ID:
              schema: { type: string }
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/SimSwapRiskResult'
        '400':
          description: Invalid request.
        '401':
          description: Missing or invalid access token.
        '403':
          description: Partner is not authorized for this Open Gateway product.
        '429':
          description: Runtime SIM Swap partner/application fair-use limit exceeded.
          headers:
            Retry-After:
              schema: { type: integer, example: 15 }
            RateLimit-Limit:
              schema: { type: integer, example: 6 }
            RateLimit-Remaining:
              schema: { type: integer, example: 0 }
            RateLimit-Reset:
              schema: { type: integer, example: 15 }
            RateLimit-Policy:
              schema: { type: string, example: TelcoSiddhiSimSwapFraudFairUsePolicy }
            X-Correlation-ID:
              schema: { type: string }
          content:
            application/problem+json:
              schema:
                $ref: '#/components/schemas/Problem'
components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        clientCredentials:
          tokenUrl: https://localhost:9443/oauth2/token
          scopes:
            opengateway_sim_swap: Read SIM swap risk signals for fraud-prevention use cases.
  schemas:
    SimSwapRiskResult:
      type: object
      required: [msisdn, riskLevel, riskScore]
      properties:
        msisdn: { type: string }
        country: { type: string }
        lastSimChangeAt: { type: string, format: date-time }
        hoursSinceLastSimChange: { type: integer }
        riskLevel: { type: string, enum: [LOW, MEDIUM, HIGH, CRITICAL] }
        riskScore: { type: integer, minimum: 0, maximum: 100 }
        coolingOffRecommended: { type: boolean }
        recommendedAction: { type: string, enum: [ALLOW, STEP_UP, HOLD_TRANSACTION, BLOCK] }
        partnerId: { type: string }
        correlationId: { type: string }
        timestamp: { type: string, format: date-time }
    Problem:
      type: object
      required: [title, status, correlationId]
      properties:
        type: { type: string }
        title: { type: string }
        status: { type: integer }
        code: { type: string }
        detail: { type: string }
        policyName: { type: string }
        partnerId: { type: string }
        apiName: { type: string }
        apiContext: { type: string }
        apiVersion: { type: string }
        applicationId: { type: string }
        applicationName: { type: string }
        correlationId: { type: string }
        retryAfterSeconds: { type: integer }
        rateLimit: { type: integer }
YAML
done

log "Adding the MI service contract used by Service Catalog and verification"
for oas in contracts/openapi/runtime-policy-alert.openapi.yaml artifacts/contracts/openapi/runtime-policy-alert.openapi.yaml; do
  write_file "$oas" <<'YAML'
openapi: 3.0.3
info:
  title: Runtime Policy Alert API
  version: 1.0.0
  description: >-
    Internal WSO2 Integrator: MI service that validates APIM runtime throttling
    alerts and publishes them to the telco.runtime.policy.alerts Kafka topic.
servers:
  - url: http://wso2-mi:8290/internal/runtime-policy-alerts/v1
paths:
  /health:
    get:
      operationId: getRuntimePolicyAlertHealth
      summary: Check the runtime policy alert integration health
      responses:
        '200':
          description: Service is running
  /events:
    post:
      operationId: publishRuntimePolicyAlert
      summary: Validate and publish a runtime policy alert
      parameters:
        - name: X-Correlation-ID
          in: header
          required: true
          schema: { type: string }
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/RuntimePolicyAlert'
      responses:
        '202':
          description: Alert accepted and published to Kafka
        '400':
          description: Required identity/correlation field missing
        '503':
          description: Kafka endpoint unavailable, timed out or suspended
components:
  schemas:
    RuntimePolicyAlert:
      type: object
      required: [eventType, policyName, partnerId, apiContext, applicationId, correlationId]
      properties:
        eventType: { type: string, example: TELCO_RUNTIME_POLICY_THROTTLED }
        eventVersion: { type: string, example: '1.0' }
        occurredAt: { type: string, format: date-time }
        policyName: { type: string }
        partnerId: { type: string }
        apiName: { type: string }
        apiContext: { type: string }
        apiVersion: { type: string }
        applicationId: { type: string }
        applicationName: { type: string }
        correlationId: { type: string }
        httpStatus: { type: integer, example: 429 }
        errorCode: { type: string, example: '900806' }
        retryAfterSeconds: { type: integer }
        rateLimit: { type: integer }
        source: { type: string }
YAML
done

log "Adding repository documentation and Postman assets"
write_file docs/siddhi-runtime-enforcement.md <<'MD'
# Runtime enforcement of the Siddhi controls

## Purpose

The custom throttling policies are no longer only visible configuration in APIM Admin. Their Siddhi predicates match the real published API contexts and versions, the APIM Traffic Manager evaluates request events, and the Classic Gateway returns a normalized 429 response while publishing an operational alert through WSO2 Integrator: MI to Kafka.

## Runtime controls

| Policy | Key | Demo condition | Retry-After | Public API |
|---|---|---:|---:|---|
| `TelcoSiddhiSimSwapFraudFairUsePolicy` | APIM application + API context + version | 6 requests / 15-second time batch | 15 seconds | `OpenGatewaySimSwapRiskAPI:1.0.0` |
| `TelcoSiddhiQoDAssuranceBurstPolicy` | API context + version | 9 requests / 5-second time batch | 5 seconds | `NetworkSliceAPI:1.0.0` QoD operation |

These values are deliberately small for deterministic demonstration. They are not production recommendations.

## Enforcement and alert path

1. A subscribed application invokes the SIM Swap or QoD operation through APIM.
2. The Gateway emits request metadata to the Traffic Manager.
3. The custom Siddhi policy groups the matching stream by its configured key.
4. When the time-batch threshold is exceeded, APIM returns `429 Too Many Requests`.
5. The `_throttle_out_handler_` sequence adds `Retry-After`, standard `RateLimit-*`, compatibility `X-RateLimit-*`, policy and correlation headers, plus an `application/problem+json` body.
6. The sequence asynchronously clones a normalized alert to the MI-managed `RuntimePolicyAlertAPI`.
7. MI validates policy, partner, API, application and correlation identity.
8. MI calls the backend Kafka bridge with a 1.5-second timeout, two bounded retries, endpoint suspension and exponential recovery.
9. The backend publishes the event to `telco.runtime.policy.alerts` in Redpanda/Kafka.

Alert publication is intentionally partial and non-blocking. If MI or Kafka is unavailable, the consumer still receives the correct 429; the alert clone cannot replace that response.

## Consumer behavior

Consumers must preserve `X-Correlation-ID`, send a stable `X-Partner-Id`, honor `Retry-After`, and use bounded exponential backoff with jitter. A 429 must not be retried immediately or bypassed through duplicate applications.

The alert contains operational identity only. It does not contain the SIM Swap MSISDN, QoD device, location or request body. Consent and legal-basis requirements for the underlying API operation remain unchanged.

## Build and start

For a clean rebuild that removes the previous APIM/bootstrap state:

```bash
COMPOSE=(docker compose \
  -f docker-compose.yml \
  -f docker-compose.kafka.yml \
  -f docker-compose.opa.yml \
  -f docker-compose.mi.yml \
  -f docker-compose.mi.soap.yml \
  -f docker-compose.observability.yml \
  -f docker-compose.runtime-persistence.yml \
  -f docker-compose.siddhi-runtime.yml)

"${COMPOSE[@]}" down -v --remove-orphans
NO_CACHE=1 ./scripts/start-siddhi-runtime-enforcement.sh
```

The start helper builds the changed images, starts the complete topology once,
waits for APIM/MI/backend health, waits for the one-shot bootstrapper to finish,
registers the MI services in Service Catalog and then starts any dependent portals.

## Verification

```bash
./scripts/verify-siddhi-runtime-enforcement.sh
```

The verifier checks policy deployment and query matching, API/Product publication, commercial policies, Developer Portal documents, QoD definition, MI Service Catalog registration, health, live 429 headers/body, and Kafka events containing partner/API/application/correlation identity.

## Postman and SDK guidance

Import `artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json`. Obtain an OAuth token from the existing `Regional Portal` application or another subscribed application and set the collection variables. The updated public OpenAPI definitions are used by APIM for Try Out and SDK generation; generated clients still need explicit 429 retry/backoff handling.
MD

write_file artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json <<'JSON'
{
  "info": {
    "_postman_id": "0c66a5f0-4b32-4e47-8d0c-0f3a11e696aa",
    "name": "Telco Siddhi Runtime Enforcement",
    "description": "Live SIM Swap fair-use and QoD assurance burst examples. Repeat the requests rapidly to trigger APIM 429 responses and inspect Kafka alerts.",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "variable": [
    { "key": "apimBaseUrl", "value": "https://localhost:9443" },
    { "key": "gatewayBaseUrl", "value": "https://localhost:8243" },
    { "key": "backendBaseUrl", "value": "http://localhost:8081" },
    { "key": "clientId", "value": "" },
    { "key": "clientSecret", "value": "" },
    { "key": "accessToken", "value": "" },
    { "key": "partnerId", "value": "digital-bank-demo" },
    { "key": "correlationId", "value": "siddhi-postman-demo-001" }
  ],
  "item": [
    {
      "name": "1. OAuth token",
      "request": {
        "auth": {
          "type": "basic",
          "basic": [
            { "key": "username", "value": "{{clientId}}", "type": "string" },
            { "key": "password", "value": "{{clientSecret}}", "type": "string" }
          ]
        },
        "method": "POST",
        "header": [
          { "key": "Content-Type", "value": "application/x-www-form-urlencoded" }
        ],
        "body": {
          "mode": "urlencoded",
          "urlencoded": [
            { "key": "grant_type", "value": "client_credentials", "type": "text" },
            { "key": "scope", "value": "opengateway_sim_swap network.qod.request", "type": "text" }
          ]
        },
        "url": "{{apimBaseUrl}}/oauth2/token"
      },
      "event": [
        {
          "listen": "test",
          "script": {
            "exec": [
              "const body = pm.response.json();",
              "pm.collectionVariables.set('accessToken', body.access_token);",
              "pm.test('Access token returned', () => pm.expect(body.access_token).to.be.a('string'));"
            ],
            "type": "text/javascript"
          }
        }
      ]
    },
    {
      "name": "2. SIM Swap fair-use request (repeat rapidly)",
      "request": {
        "method": "GET",
        "header": [
          { "key": "Authorization", "value": "Bearer {{accessToken}}" },
          { "key": "X-Partner-Id", "value": "{{partnerId}}" },
          { "key": "X-Correlation-ID", "value": "{{correlationId}}" },
          { "key": "Accept", "value": "application/json" }
        ],
        "url": "{{gatewayBaseUrl}}/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168"
      }
    },
    {
      "name": "3. QoD assurance request (repeat rapidly)",
      "request": {
        "method": "POST",
        "header": [
          { "key": "Authorization", "value": "Bearer {{accessToken}}" },
          { "key": "X-Partner-Id", "value": "enterprise-qod-demo" },
          { "key": "X-Correlation-ID", "value": "{{correlationId}}" },
          { "key": "Content-Type", "value": "application/json" }
        ],
        "body": {
          "mode": "raw",
          "raw": "{\n  \"device\": { \"phoneNumber\": \"+525512340001\" },\n  \"area\": { \"type\": \"CELL_ID\", \"value\": \"MX-MEX-CELL-001\" },\n  \"profile\": \"QOD_GOLD\",\n  \"durationSeconds\": 120,\n  \"maxLatencyMs\": 20,\n  \"minThroughputMbps\": 100\n}"
        },
        "url": "{{gatewayBaseUrl}}/network-slice/v1/1.0.0/api/v1/network/qod/sessions"
      }
    },
    {
      "name": "4. Inspect runtime policy Kafka alerts",
      "request": {
        "method": "GET",
        "header": [],
        "url": "{{backendBaseUrl}}/api/v1/kafka/topics/telco.runtime.policy.alerts/events"
      }
    }
  ]
}
JSON

write_file scripts/start-siddhi-runtime-enforcement.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

files=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.siddhi-runtime.yml
)
compose=(docker compose)
for file in "${files[@]}"; do
  [[ -f "$file" ]] && compose+=( -f "$file" )
done

wait_url() {
  local label="$1" url="$2" attempts="${3:-120}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if curl -ksSf "$url" >/dev/null 2>&1; then
      printf '[start-siddhi-runtime] %s is ready.\n' "$label"
      return 0
    fi
    sleep 3
  done
  printf '[start-siddhi-runtime] ERROR: %s did not become ready: %s\n' "$label" "$url" >&2
  return 1
}

wait_bootstrapper() {
  local i cid status exit_code
  for ((i=1; i<=240; i++)); do
    cid="$("${compose[@]}" ps -aq apim-bootstrapper 2>/dev/null | head -n1)"
    if [[ -n "$cid" ]]; then
      read -r status exit_code < <(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid")
      if [[ "$status" == 'exited' ]]; then
        if [[ "$exit_code" == '0' ]]; then
          printf '[start-siddhi-runtime] APIM bootstrapper completed successfully.\n'
          return 0
        fi
        "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
        printf '[start-siddhi-runtime] ERROR: APIM bootstrapper exited with code %s.\n' "$exit_code" >&2
        return 1
      fi
      if [[ "$status" == 'dead' ]]; then
        "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
        printf '[start-siddhi-runtime] ERROR: APIM bootstrapper container is dead.\n' >&2
        return 1
      fi
    fi
    sleep 3
  done
  "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
  printf '[start-siddhi-runtime] ERROR: APIM bootstrapper did not complete.\n' >&2
  return 1
}

if [[ "${NO_CACHE:-0}" == '1' ]]; then
  "${compose[@]}" build --no-cache wso2-apim wso2-mi telco-backend apim-bootstrapper
else
  "${compose[@]}" build wso2-apim wso2-mi telco-backend apim-bootstrapper
fi
# Start the complete topology once. Compose dependency conditions keep the
# one-shot bootstrapper behind APIM/MI/backend/Kafka health and allow any portal
# services that depend on successful bootstrap completion to start normally.
"${compose[@]}" up -d --remove-orphans
wait_url 'Telco backend' 'http://127.0.0.1:8081/health' 80
wait_url 'WSO2 API Manager' 'https://127.0.0.1:9443/services/Version' 160
wait_url 'RuntimePolicyAlertAPI' 'http://127.0.0.1:8290/internal/runtime-policy-alerts/v1/health' 160
wait_bootstrapper
./scripts/register-mi-service-catalog.sh
"${compose[@]}" up -d --remove-orphans
printf '\n[start-siddhi-runtime] Environment started and bootstrapped.\n'
printf '[start-siddhi-runtime] Run ./scripts/verify-siddhi-runtime-enforcement.sh\n'
SH
chmod +x scripts/start-siddhi-runtime-enforcement.sh

log "Adding complete static, management-plane and runtime verification"
write_file scripts/verify-siddhi-runtime-enforcement.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_APIM_GATEWAY_PUBLIC_URL:-https://127.0.0.1:8243}"
BACKEND_URL="${TELCO_BACKEND_PUBLIC_URL:-http://127.0.0.1:8081}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD_VALUE="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-siddhi-runtime.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
require_file() { [[ -f "$1" ]] || fail "Missing file: $1"; }

for cmd in curl jq python3 docker awk grep sed; do require "$cmd"; done

files=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.siddhi-runtime.yml
)
compose=(docker compose)
for file in "${files[@]}"; do
  [[ -f "$file" ]] && compose+=( -f "$file" )
done

json_curl() {
  curl -ksS --fail-with-body "$@"
}

http_json() {
  local method="$1" url="$2" token="$3"
  shift 3
  curl -ksS --fail-with-body -X "$method" \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/json' \
    "$@" "$url"
}

printf '\n=== Static artifact verification ===\n'
for file in \
  artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json \
  services/wso2-apim/sequences/_throttle_out_handler_.xml \
  services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml \
  services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml \
  contracts/openapi/network-slice.openapi.yaml \
  contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml \
  contracts/openapi/runtime-policy-alert.openapi.yaml \
  artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json \
  services/apim-bootstrapper/src/siddhi-runtime-enforcement-setup.js \
  docs/siddhi-runtime-enforcement.md; do
  require_file "$file"
done

jq -e '
  length == 2 and
  any(.[]; .policyName == "TelcoSiddhiSimSwapFraudFairUsePolicy" and
      .keyTemplate == "$appId:$apiContext:$apiVersion" and
      (.siddhiQuery | contains("/open-gateway/sim-swap/v1")) and
      (.siddhiQuery | contains("count(throttleKey) >= 6")) and
      (.siddhiQuery | contains("timeBatch(15 sec)"))) and
  any(.[]; .policyName == "TelcoSiddhiQoDAssuranceBurstPolicy" and
      .keyTemplate == "$apiContext:$apiVersion" and
      (.siddhiQuery | contains("/network-slice/v1")) and
      (.siddhiQuery | contains("count(throttleKey) >= 9")) and
      (.siddhiQuery | contains("timeBatch(5 sec)")))
' artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json >/dev/null \
  || fail 'Custom policy artifact does not contain the expected runtime keys, contexts and thresholds.'
pass 'Custom Siddhi policy artifact matches the deployed API contexts.'

python3 - <<'PY'
import json
import xml.etree.ElementTree as ET
from pathlib import Path
for p in [
    Path('services/wso2-apim/sequences/_throttle_out_handler_.xml'),
    Path('services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml'),
    Path('services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml'),
]:
    ET.parse(p)
json.loads(Path('artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json').read_text())
json.loads(Path('services/apim-bootstrapper/package.json').read_text())
PY
pass 'APIM/MI XML and JSON artifacts are well formed.'

grep -q 'createQualityOnDemandSession' contracts/openapi/network-slice.openapi.yaml \
  || fail 'QoD operation is absent from NetworkSliceAPI contract.'
grep -q 'network.qod.request' contracts/openapi/network-slice.openapi.yaml \
  || fail 'QoD OAuth scope is absent from NetworkSliceAPI contract.'
grep -q 'TelcoSiddhiSimSwapFraudFairUsePolicy' contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml \
  || fail 'SIM Swap runtime 429 contract is absent.'
grep -q 'telco.runtime.policy.alerts' services/telco-backend/src/kafka-broker.js \
  || fail 'Kafka alert topic is absent from backend topic list.'
grep -q 'RuntimePolicyAlertAPI' scripts/register-mi-service-catalog.sh \
  || fail 'RuntimePolicyAlertAPI is absent from Service Catalog registration.'
grep -q 'siddhi-runtime-enforcement-setup.js' services/apim-bootstrapper/package.json \
  || fail 'Runtime documentation bootstrap is absent from package start order.'
pass 'Contracts, Kafka topic, Service Catalog and bootstrap order are patched.'

printf '\n=== Runtime health verification ===\n'
json_curl "${APIM_URL}/services/Version" >/dev/null || fail 'APIM is not reachable.'
pass 'WSO2 API Manager is reachable.'
json_curl "${MI_URL}/internal/runtime-policy-alerts/v1/health" \
  | jq -e '.status == "UP" and .service == "RuntimePolicyAlertAPI"' >/dev/null \
  || fail 'RuntimePolicyAlertAPI health check failed.'
pass 'WSO2 Integrator RuntimePolicyAlertAPI is healthy.'
json_curl "${BACKEND_URL}/health" >/dev/null || fail 'Telco backend is not healthy.'
KAFKA_STATUS="$(json_curl "${BACKEND_URL}/api/v1/kafka/status")"
printf '%s' "$KAFKA_STATUS" | jq -e '.enabled == true and .connected == true and (.topics | index("telco.runtime.policy.alerts")) != null' >/dev/null \
  || fail 'Kafka is not enabled or runtime policy alert topic is missing.'
pass 'Kafka/Redpanda is enabled and the runtime alert topic is registered.'

printf '\n=== APIM OAuth client registration ===\n'
DCR_RESPONSE="$(
  curl -ksS --fail-with-body \
    -u "${APIM_USER}:${APIM_PASSWORD_VALUE}" \
    -H 'Content-Type: application/json' \
    -d "{\"callbackUrl\":\"http://localhost:8080/callback\",\"clientName\":\"telco-siddhi-runtime-verifier-$(date +%s)-$$\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
    "${APIM_URL}/client-registration/v0.17/register"
)"
CLIENT_ID="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientId // empty')"
CLIENT_SECRET="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientSecret // empty')"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail 'Dynamic client registration did not return credentials.'
pass 'Verifier OAuth client registered.'

password_token() {
  local scope="$1"
  curl -ksS --fail-with-body \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD_VALUE}" \
    --data-urlencode "scope=${scope}" \
    "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty'
}

ADMIN_TOKEN="$(password_token 'apim:admin_tier_view apim:admin_tier_manage')"
PUBLISHER_TOKEN="$(password_token 'apim:api_view apim:api_metadata_view apim:api_product_view apim:document_manage apim:document_create apim:document_update')"
CATALOG_TOKEN="$(password_token 'service_catalog:service_view service_catalog:service_write')"
DEVPORTAL_TOKEN="$(password_token 'apim:subscribe')"
[[ -n "$ADMIN_TOKEN" && -n "$PUBLISHER_TOKEN" && -n "$CATALOG_TOKEN" && -n "$DEVPORTAL_TOKEN" ]] \
  || fail 'Could not obtain all management-plane access tokens.'
pass 'Admin, Publisher, Developer Portal and Service Catalog tokens obtained.'

printf '\n=== Custom throttling policy verification ===\n'
CUSTOM_POLICIES="$(http_json GET "${APIM_URL}/api/am/admin/v4/throttling/policies/custom?limit=1000" "$ADMIN_TOKEN")"
policy_exists() {
  local name="$1" context="$2" expression="$3" window="$4"
  printf '%s' "$CUSTOM_POLICIES" | jq -e \
    --arg name "$name" --arg context "$context" --arg expression "$expression" --arg window "$window" '
      (if type == "array" then . else (.list // .data // []) end)
      | any(.[];
          .policyName == $name and
          (.isDeployed // true) != false and
          (.siddhiQuery | contains($context)) and
          (.siddhiQuery | contains($expression)) and
          (.siddhiQuery | contains($window)))
    ' >/dev/null
}
policy_exists 'TelcoSiddhiSimSwapFraudFairUsePolicy' '/open-gateway/sim-swap/v1' 'count(throttleKey) >= 6' 'timeBatch(15 sec)' \
  || fail 'SIM Swap custom policy is missing, undeployed or stale in APIM.'
policy_exists 'TelcoSiddhiQoDAssuranceBurstPolicy' '/network-slice/v1' 'count(throttleKey) >= 9' 'timeBatch(5 sec)' \
  || fail 'QoD custom policy is missing, undeployed or stale in APIM.'
pass 'Both custom policies are deployed with live API matching.'

printf '\n=== API, deployment, document and product verification ===\n'
APIS="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis?limit=1000" "$PUBLISHER_TOKEN")"
api_id() {
  local name="$1"
  printf '%s' "$APIS" | jq -r --arg name "$name" 'first((if type == "array" then . else (.list // .data // []) end)[]? | select(.name == $name and .version == "1.0.0") | .id) // empty'
}
verify_api() {
  local name="$1"
  local id state deployments docs
  id="$(api_id "$name")"
  [[ -n "$id" ]] || fail "Required API not found: ${name}:1.0.0"
  state="$(printf '%s' "$APIS" | jq -r --arg id "$id" 'first(.list[]? | select(.id == $id) | (.lifeCycleStatus // .state // ""))')"
  [[ "$state" == 'PUBLISHED' ]] || fail "${name}:1.0.0 is not PUBLISHED (state=${state})."
  deployments="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${id}/deployments" "$PUBLISHER_TOKEN")"
  printf '%s' "$deployments" | jq -e '((if type == "array" then . else (.list // .data // []) end) | length) > 0' >/dev/null \
    || fail "${name}:1.0.0 has no Gateway deployment."
  docs="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${id}/documents?limit=100" "$PUBLISHER_TOKEN")"
  for expected in \
    '01 - Business Overview' \
    '02 - Contract and CAMARA Alignment' \
    '03 - Authentication and First Call' \
    '04 - Consent and Privacy Requirements' \
    '05 - Error Catalogue' \
    '06 - Rate Limits and Commercial Plan' \
    '07 - SLA Support and Resilience' \
    '08 - Code Samples Postman and SDKs' \
    '09 - Sandbox Test Data' \
    '10 - Runtime Business Controls'; do
    printf '%s' "$docs" | jq -e --arg name "$expected" 'any(.list[]?; .name == $name)' >/dev/null \
      || fail "${name}:1.0.0 is missing Developer Portal document: ${expected}"
  done
  pass "${name}:1.0.0 is published, deployed and has all ten consumer documents." >&2
  printf '%s' "$id"
}

SIM_API_ID="$(verify_api OpenGatewaySimSwapRiskAPI | tail -n1)"
QOD_API_ID="$(verify_api NetworkSliceAPI | tail -n1)"

SIM_SWAGGER="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${SIM_API_ID}/swagger" "$PUBLISHER_TOKEN")"
printf '%s' "$SIM_SWAGGER" | grep -q 'TelcoSiddhiSimSwapFraudFairUsePolicy' \
  || fail 'Published SIM Swap definition does not document the runtime policy.'
QOD_SWAGGER="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${QOD_API_ID}/swagger" "$PUBLISHER_TOKEN")"
printf '%s' "$QOD_SWAGGER" | grep -q 'createQualityOnDemandSession' \
  || fail 'Published NetworkSliceAPI does not contain the QoD operation.'
printf '%s' "$QOD_SWAGGER" | grep -q 'network.qod.request' \
  || fail 'Published NetworkSliceAPI does not contain the QoD OAuth scope.'
pass 'Published API definitions contain the runtime 429 contracts and QoD scope.'

PRODUCTS="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000" "$PUBLISHER_TOKEN")"
verify_product() {
  local name="$1" member="$2" operation_marker="$3" id state detail revisions swagger
  id="$(printf '%s' "$PRODUCTS" | jq -r --arg name "$name" 'first((if type == "array" then . else (.list // .data // []) end)[]? | select(.name == $name and .version == "1.0.0") | .id) // empty')"
  [[ -n "$id" ]] || fail "Required API Product not found: ${name}:1.0.0"
  state="$(printf '%s' "$PRODUCTS" | jq -r --arg id "$id" 'first((if type == "array" then . else (.list // .data // []) end)[]? | select(.id == $id) | (.state // .lifeCycleStatus // ""))')"
  [[ "$state" == 'PUBLISHED' ]] || fail "${name}:1.0.0 is not PUBLISHED (state=${state})."
  detail="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}" "$PUBLISHER_TOKEN")"
  printf '%s' "$detail" | jq -e --arg member "$member" 'any(.apis[]?; (.name // .apiName) == $member)' >/dev/null \
    || fail "${name}:1.0.0 does not contain ${member}."
  swagger="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}/swagger" "$PUBLISHER_TOKEN")"
  printf '%s' "$swagger" | grep -q "$operation_marker" \
    || fail "${name}:1.0.0 does not expose operation marker ${operation_marker}."
  revisions="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}/revisions" "$PUBLISHER_TOKEN")"
  printf '%s' "$revisions" | jq -e '((if type == "array" then . else (.list // .data // []) end) | length) > 0' >/dev/null \
    || fail "${name}:1.0.0 has no revision."
  pass "${name}:1.0.0 is published, revisioned and exposes ${member}/${operation_marker}."
}
verify_product OpenGatewayFraudDefenseProduct OpenGatewaySimSwapRiskAPI getSimSwapRisk
verify_product FiveGNetworkMonetizationProduct NetworkSliceAPI createQualityOnDemandSession

SUBSCRIPTION_POLICIES="$(http_json GET "${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000" "$ADMIN_TOKEN")"
for policy in TelcoFreeTrial TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium TelcoPartnerStandard TelcoPartnerPremium; do
  printf '%s' "$SUBSCRIPTION_POLICIES" | jq -e --arg p "$policy" '
    (if type == "array" then . else (.list // .data // []) end) | any(.[]; .policyName == $p)
  ' >/dev/null || fail "Required commercial/subscription policy missing: ${policy}"
done
pass 'All required commercial/subscription policies are present.'

DEVPORTAL_APIS="$(curl -ksS --fail-with-body -H "Authorization: Bearer ${DEVPORTAL_TOKEN}" -H 'X-WSO2-Tenant: carbon.super' "${APIM_URL}/api/am/devportal/v3/apis?limit=1000")"
for api in OpenGatewaySimSwapRiskAPI NetworkSliceAPI; do
  printf '%s' "$DEVPORTAL_APIS" | jq -e --arg api "$api" 'any(.list[]?; .name == $api and .version == "1.0.0")' >/dev/null \
    || fail "${api}:1.0.0 is not visible through the Developer Portal API."
done
# APIM 4.7 exposes APIs and API Products through the same DevPortal
# marketplace listing. There is no separate /api-products collection route.
DEVPORTAL_PRODUCTS="$DEVPORTAL_APIS"
for product in OpenGatewayFraudDefenseProduct FiveGNetworkMonetizationProduct; do
  printf '%s' "$DEVPORTAL_PRODUCTS" | jq -e --arg product "$product" '
    (if type == "array" then . else (.list // .data // []) end)
    | any(.[]?; .name == $product and .version == "1.0.0")
  ' >/dev/null \
    || fail "${product}:1.0.0 is not visible through the Developer Portal API."
done
pass 'Affected APIs and API Products are visible in the Developer Portal.'

printf '\n=== MI Service Catalog verification ===\n'
CATALOG="$(http_json GET "${APIM_URL}/api/am/service-catalog/v1/services?limit=1000" "$CATALOG_TOKEN")"
printf '%s' "$CATALOG" | jq -e '
  any(.list[]?;
      .name == "RuntimePolicyAlertAPI" and
      .version == "1.0.0" and
      .definitionType == "OAS3" and
      (.serviceUrl | contains("/internal/runtime-policy-alerts/v1")))
' >/dev/null || fail 'RuntimePolicyAlertAPI is absent or incorrect in APIM Service Catalog.'
pass 'RuntimePolicyAlertAPI is registered in APIM Service Catalog.'

printf '\n=== Subscribed application credentials ===\n'
RUNTIME_STATE="$("${compose[@]}" run --rm --no-deps --entrypoint sh apim-bootstrapper -c 'cat /workspace/state/runtime.json')"
printf '%s' "$RUNTIME_STATE" | jq -e . >/dev/null || fail 'runtime.json could not be read from the bootstrap state volume.'
APP_CREDS="$(printf '%s' "$RUNTIME_STATE" | jq -c '
  def pair:
    {id: (.consumerKey? // .clientId? // ""), secret: (.consumerSecret? // .clientSecret? // "")}
    | select((.id | type == "string" and length > 0) and (.secret | type == "string" and length > 0));
  ([.. | objects
      | select((((.name? // .applicationName? // .appName? // "") | tostring | ascii_downcase) == "regional portal"))
      | .. | objects | pair] | first)
  // ([.. | objects | pair] | first)
  // {}
')"
APP_CLIENT_ID="$(printf '%s' "$APP_CREDS" | jq -r '.id // empty')"
APP_CLIENT_SECRET="$(printf '%s' "$APP_CREDS" | jq -r '.secret // empty')"
[[ -n "$APP_CLIENT_ID" && -n "$APP_CLIENT_SECRET" ]] \
  || fail 'Regional Portal application production credentials are missing from runtime.json.'
pass 'Regional Portal application credentials found.'

application_token() {
  local scope="$1"
  local response
  response="$(curl -ksS --fail-with-body \
    -u "${APP_CLIENT_ID}:${APP_CLIENT_SECRET}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "scope=${scope}" \
    "${APIM_URL}/oauth2/token")"
  printf '%s' "$response" | jq -r '.access_token // empty'
}
SIM_TOKEN="$(application_token 'opengateway_sim_swap')"
QOD_TOKEN="$(application_token 'network.qod.request')"
[[ -n "$SIM_TOKEN" && -n "$QOD_TOKEN" ]] || fail 'Could not obtain scoped application tokens.'
pass 'Scoped SIM Swap and QoD application tokens obtained.'

resolve_url() {
  local method="$1" token="$2" partner="$3" body="$4" expected="$5"; shift 5
  local candidate status
  for candidate in "$@"; do
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS -o "$WORK_DIR/resolve-body" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H 'X-Correlation-ID: resolve-url' -H 'Content-Type: application/json' \
        -d "$body" "$candidate")"
    else
      status="$(curl -ksS -o "$WORK_DIR/resolve-body" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H 'X-Correlation-ID: resolve-url' "$candidate")"
    fi
    if [[ "$status" == "$expected" || "$status" == '429' ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    [[ "$status" == '404' ]] || fail "Gateway URL probe returned HTTP ${status} for ${candidate}: $(cat "$WORK_DIR/resolve-body")"
  done
  fail 'No valid Gateway URL candidate was found.'
}

SIM_URL="$(resolve_url GET "$SIM_TOKEN" digital-bank-demo '' 200 \
  "${GATEWAY_URL}/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168" \
  "${GATEWAY_URL}/open-gateway/sim-swap/v1/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168")"
QOD_BODY='{"device":{"phoneNumber":"+525512340001"},"area":{"type":"CELL_ID","value":"MX-MEX-CELL-001"},"profile":"QOD_GOLD","durationSeconds":120,"maxLatencyMs":20,"minThroughputMbps":100}'
QOD_URL="$(resolve_url POST "$QOD_TOKEN" enterprise-qod-demo "$QOD_BODY" 201 \
  "${GATEWAY_URL}/network-slice/v1/1.0.0/api/v1/network/qod/sessions" \
  "${GATEWAY_URL}/network-slice/v1/api/v1/network/qod/sessions")"
pass 'Gateway invocation URLs resolved.'

header_value() {
  local file="$1" name="$2"
  awk -v name="$name" 'BEGIN{IGNORECASE=1} $0 ~ "^" name ":" {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END{print value}' "$file"
}

assert_429() {
  local label="$1" header_file="$2" body_file="$3" expected_policy="$4" expected_partner="$5" expected_context="$6" expected_retry="$7" expected_limit="$8" expected_corr="$9"
  local retry limit remaining reset policy corr content_type
  retry="$(header_value "$header_file" 'Retry-After')"
  limit="$(header_value "$header_file" 'RateLimit-Limit')"
  remaining="$(header_value "$header_file" 'RateLimit-Remaining')"
  reset="$(header_value "$header_file" 'RateLimit-Reset')"
  policy="$(header_value "$header_file" 'RateLimit-Policy')"
  corr="$(header_value "$header_file" 'X-Correlation-ID')"
  content_type="$(header_value "$header_file" 'Content-Type')"
  [[ "$retry" == "$expected_retry" ]] || fail "${label}: Retry-After=${retry}, expected ${expected_retry}."
  [[ "$limit" == "$expected_limit" ]] || fail "${label}: RateLimit-Limit=${limit}, expected ${expected_limit}."
  [[ "$remaining" == '0' ]] || fail "${label}: RateLimit-Remaining=${remaining}, expected 0."
  [[ -n "$reset" ]] || fail "${label}: RateLimit-Reset header missing."
  [[ "$policy" == "$expected_policy" ]] || fail "${label}: RateLimit-Policy=${policy}, expected ${expected_policy}."
  [[ "$corr" == "$expected_corr" ]] || fail "${label}: correlation header was not preserved."
  [[ "$content_type" == application/problem+json* ]] || fail "${label}: content type is not application/problem+json."
  jq -e --arg policy "$expected_policy" --arg partner "$expected_partner" --arg context "$expected_context" --arg corr "$expected_corr" \
    '.status == 429 and .code == "900806" and .policyName == $policy and .partnerId == $partner and .apiContext == $context and .correlationId == $corr and (.applicationId | type == "string" and length > 0 and . != "null")' \
    "$body_file" >/dev/null || fail "${label}: normalized 429 body is missing policy/partner/API/application/correlation identity: $(cat "$body_file")"
}

trigger_policy() {
  local label="$1" method="$2" url="$3" token="$4" partner="$5" body="$6" threshold="$7" window="$8" policy="$9" context="${10}" retry="${11}" limit="${12}"
  local i status corr header_file body_file deadline

  printf '\n[runtime] Clearing previous %s window...\n' "$label" >&2
  sleep "$((window + 3))"
  printf '[runtime] Sending %s qualifying requests for %s...\n' "$threshold" "$label" >&2
  for i in $(seq 1 "$threshold"); do
    corr="verify-${label// /-}-fill-${i}-$(date +%s%N)"
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" -H 'Content-Type: application/json' \
        -d "$body" "$url")"
    else
      status="$(curl -ksS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" "$url")"
    fi
    [[ "$status" == '200' || "$status" == '201' || "$status" == '429' ]] \
      || fail "${label}: qualifying request ${i} returned HTTP ${status}."
  done

  deadline=$((SECONDS + window + 20))
  while (( SECONDS < deadline )); do
    corr="verify-${label// /-}-throttled-$(date +%s%N)"
    header_file="$WORK_DIR/${label// /-}.headers"
    body_file="$WORK_DIR/${label// /-}.body"
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS -D "$header_file" -o "$body_file" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" -H 'Content-Type: application/json' \
        -d "$body" "$url")"
    else
      status="$(curl -ksS -D "$header_file" -o "$body_file" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" "$url")"
    fi
    if [[ "$status" == '429' ]]; then
      assert_429 "$label" "$header_file" "$body_file" "$policy" "$partner" "$context" "$retry" "$limit" "$corr"
      printf '%s' "$corr"
      return 0
    fi
    [[ "$status" == '200' || "$status" == '201' ]] || fail "${label}: probe returned HTTP ${status}: $(cat "$body_file")"
    sleep 1
  done
  fail "${label}: no HTTP 429 was observed after the Siddhi threshold."
}

printf '\n=== Live SIM Swap runtime enforcement ===\n'
SIM_CORRELATION="$(trigger_policy 'SIM-Swap' GET "$SIM_URL" "$SIM_TOKEN" digital-bank-demo '' 6 15 \
  TelcoSiddhiSimSwapFraudFairUsePolicy /open-gateway/sim-swap/v1 15 6)"
pass 'SIM Swap fair-use policy returned normalized HTTP 429 and rate-limit headers.'

printf '\n=== Live QoD runtime enforcement ===\n'
QOD_CORRELATION="$(trigger_policy 'QoD' POST "$QOD_URL" "$QOD_TOKEN" enterprise-qod-demo "$QOD_BODY" 9 5 \
  TelcoSiddhiQoDAssuranceBurstPolicy /network-slice/v1 5 9)"
pass 'QoD assurance policy returned normalized HTTP 429 and rate-limit headers.'

verify_alert() {
  local label="$1" correlation="$2" policy="$3" partner="$4" context="$5" deadline events
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    events="$(json_curl "${BACKEND_URL}/api/v1/kafka/topics/telco.runtime.policy.alerts/events")"
    if printf '%s' "$events" | jq -e --arg corr "$correlation" --arg policy "$policy" --arg partner "$partner" --arg context "$context" '
      any(.. | objects;
          .correlationId? == $corr and
          .policyName? == $policy and
          .partnerId? == $partner and
          .apiContext? == $context and
          (.applicationId? | type == "string" and length > 0 and . != "null"))
    ' >/dev/null; then
      pass "${label} alert is present in Kafka with partner, API, application and correlation identity."
      return 0
    fi
    sleep 1
  done
  fail "${label}: matching Kafka alert was not observed within 30 seconds."
}

printf '\n=== Kafka alert evidence ===\n'
verify_alert 'SIM Swap' "$SIM_CORRELATION" TelcoSiddhiSimSwapFraudFairUsePolicy digital-bank-demo /open-gateway/sim-swap/v1
verify_alert 'QoD' "$QOD_CORRELATION" TelcoSiddhiQoDAssuranceBurstPolicy enterprise-qod-demo /network-slice/v1

printf '\n============================================================\n'
printf 'SIDDHI RUNTIME ENFORCEMENT VERIFICATION PASSED\n'
printf 'SIM correlation: %s\n' "$SIM_CORRELATION"
printf 'QoD correlation: %s\n' "$QOD_CORRELATION"
printf 'Kafka topic: telco.runtime.policy.alerts\n'
printf '============================================================\n'
SH
chmod +x scripts/verify-siddhi-runtime-enforcement.sh

log "Updating README navigation"
python3 - <<'PY'
from pathlib import Path
p = Path('README.md')
if p.exists():
    text = p.read_text(encoding='utf-8')
    marker = '<!-- BEGIN SIDDHI RUNTIME ENFORCEMENT -->'
    if marker not in text:
        section = '''

<!-- BEGIN SIDDHI RUNTIME ENFORCEMENT -->
## Runtime Siddhi business controls

The SIM Swap fair-use and Quality-on-Demand assurance policies are attached to the live APIM request stream and demonstrate normalized HTTP 429 responses, `Retry-After`/rate-limit headers, MI-mediated Kafka alerts and partner/API/application/correlation evidence.

- Architecture, consumer guidance and commands: [`docs/siddhi-runtime-enforcement.md`](docs/siddhi-runtime-enforcement.md)
- Start helper: `./scripts/start-siddhi-runtime-enforcement.sh`
- Full verification: `./scripts/verify-siddhi-runtime-enforcement.sh`
- Postman collection: `artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json`
<!-- END SIDDHI RUNTIME ENFORCEMENT -->
'''
        p.write_text(text.rstrip() + section + '\n', encoding='utf-8')
PY

log "Running installer-time static validation"
bash -n scripts/start-siddhi-runtime-enforcement.sh
bash -n scripts/verify-siddhi-runtime-enforcement.sh
python3 - <<'PY'
import json
import xml.etree.ElementTree as ET
from pathlib import Path

json_files = [
    'artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json',
    'artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json',
    'services/apim-bootstrapper/package.json',
]
for name in json_files:
    json.loads(Path(name).read_text(encoding='utf-8'))

xml_files = [
    'services/wso2-apim/sequences/_throttle_out_handler_.xml',
    'services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml',
    'services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml',
]
for name in xml_files:
    ET.parse(name)

policy = json.loads(Path(json_files[0]).read_text(encoding='utf-8'))
assert len(policy) == 2
assert any(p['policyName'] == 'TelcoSiddhiSimSwapFraudFairUsePolicy' and '/open-gateway/sim-swap/v1' in p['siddhiQuery'] for p in policy)
assert any(p['policyName'] == 'TelcoSiddhiQoDAssuranceBurstPolicy' and '/network-slice/v1' in p['siddhiQuery'] for p in policy)

package = json.loads(Path('services/apim-bootstrapper/package.json').read_text(encoding='utf-8'))
steps = [part.strip() for part in package['scripts']['start'].split('&&')]
assert steps.count('node src/siddhi-runtime-enforcement-setup.js') == 1
if 'node src/api-product-bundles-setup.js' in steps:
    assert steps.index('node src/siddhi-runtime-enforcement-setup.js') < steps.index('node src/api-product-bundles-setup.js')

throttle_sequence = Path('services/wso2-apim/sequences/_throttle_out_handler_.xml').read_text(encoding='utf-8')
assert 'regex="^900806$"' in throttle_sequence
assert 'telco.isRuntimePolicy' in throttle_sequence

required_text = {
    'services/telco-backend/src/server.js': 'BEGIN SIDDHI RUNTIME QOD DEMO ROUTE',
    'services/telco-backend/src/kafka-broker.js': 'telco.runtime.policy.alerts',
    'services/wso2-apim/Dockerfile': 'BEGIN TELCO SIDDHI RUNTIME ENFORCEMENT',
    'services/wso2-mi/conf/file.properties': 'runtime_policy_kafka_url=',
    'scripts/register-mi-service-catalog.sh': 'RuntimePolicyAlertAPI',
    'contracts/openapi/network-slice.openapi.yaml': 'createQualityOnDemandSession',
    'contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml': 'TelcoSiddhiSimSwapFraudFairUsePolicy',
}
for name, needle in required_text.items():
    assert needle in Path(name).read_text(encoding='utf-8'), f'{needle} missing from {name}'
PY

if command -v node >/dev/null 2>&1; then
  node --check services/telco-backend/src/server.js
  node --check services/apim-bootstrapper/src/siddhi-runtime-enforcement-setup.js
fi

if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
  for file in docker-compose.yml docker-compose.kafka.yml docker-compose.opa.yml docker-compose.mi.yml docker-compose.mi.soap.yml docker-compose.observability.yml docker-compose.runtime-persistence.yml docker-compose.siddhi-runtime.yml; do
    [[ -f "$file" ]] && compose+=( -f "$file" )
  done
  "${compose[@]}" config --quiet
fi

log "Installation complete"
cat <<'OUT'
Created or modified:
  artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json
  artifacts/contracts/openapi/network-slice.openapi.yaml
  artifacts/contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml
  artifacts/contracts/openapi/runtime-policy-alert.openapi.yaml
  artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json
  contracts/openapi/network-slice.openapi.yaml
  contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml
  contracts/openapi/runtime-policy-alert.openapi.yaml
  docker-compose.siddhi-runtime.yml
  docs/siddhi-runtime-enforcement.md
  README.md
  scripts/register-mi-service-catalog.sh
  scripts/start-siddhi-runtime-enforcement.sh
  scripts/verify-siddhi-runtime-enforcement.sh
  services/apim-bootstrapper/package.json
  services/apim-bootstrapper/src/siddhi-runtime-enforcement-setup.js
  services/telco-backend/src/kafka-broker.js
  services/telco-backend/src/server.js
  services/wso2-apim/Dockerfile
  services/wso2-apim/sequences/_throttle_out_handler_.xml
  services/wso2-mi/conf/file.properties
  services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml
  services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml

Next commands:
  ./scripts/start-siddhi-runtime-enforcement.sh
  ./scripts/verify-siddhi-runtime-enforcement.sh
OUT

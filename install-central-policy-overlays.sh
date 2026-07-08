#!/usr/bin/env bash
set -euo pipefail

# Central policy with country-specific OPA overlays for:
# https://github.com/joaokuntzwso2/demo-apim-telco-environment
#
# Run from the repository root:
#   chmod +x install-central-policy-overlays.sh
#   ./install-central-policy-overlays.sh
#
# The script is intentionally idempotent. Generated files are replaced with
# deterministic content; existing source files are patched only when the
# marker being installed is absent.

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

fail() {
  printf '[central-policy-install] ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[central-policy-install] %s\n' "$*"
}

[[ -f docker-compose.yml ]] || fail "Run this script from the demo-apim-telco-environment repository root."
[[ -f services/apim-bootstrapper/src/bootstrap.js ]] || fail "APIM bootstrapper source was not found."
[[ -f services/wso2-mi/Dockerfile ]] || fail "WSO2 Integrator: MI Dockerfile was not found."

STAMP="$(date +%Y%m%d-%H%M%S)"
backup_once() {
  local file="$1"
  if [[ -f "$file" && ! -f "${file}.backup.${STAMP}" ]]; then
    cp -p "$file" "${file}.backup.${STAMP}"
  fi
}

for file in \
  services/apim-bootstrapper/src/bootstrap.js \
  services/apim-bootstrapper/src/developer-experience-setup.js \
  services/apim-bootstrapper/src/api-product-bundles-setup.js \
  services/apim-bootstrapper/package.json \
  artifacts/apim-admin/api-product-bundles.json \
  scripts/telco-demo-control.sh
do
  backup_once "$file"
done

mkdir -p \
  artifacts/opa \
  artifacts/apim-admin \
  artifacts/developer-experience/central-policy \
  artifacts/postman \
  artifacts/contracts/openapi \
  contracts/openapi \
  services/wso2-mi/synapse-configs/default/api \
  services/wso2-mi/synapse-configs/default/endpoints \
  services/wso2-mi/synapse-configs/default/sequences \
  services/apim-bootstrapper/src \
  scripts

log "Writing the central OPA policy."

cat > artifacts/opa/central-policy-overlays.rego <<'REGO'
package telco.central_policy

import rego.v1

policy_version := "2026.07.1"
group_policy_version := "TELCO-GROUP-2026.1"

health := {
  "status": "UP",
  "policy": "telco.central_policy",
  "policyVersion": policy_version,
  "groupPolicyVersion": group_policy_version,
}

production if upper(object.get(input, "lifecycle", "")) == "PRODUCTION"

risk := upper(object.get(input, "riskClassification", ""))
country := upper(object.get(input, "country", ""))
data_residency := upper(object.get(input, "dataResidency", ""))

high_risk := risk in {"HIGH", "CRITICAL"}

present(value) if {
  is_string(value)
  count(trim(value, " \t\r\n")) > 0
}

present(value) if {
  is_number(value)
}

present(value) if {
  is_boolean(value)
}

present(value) if {
  is_array(value)
  count(value) > 0
}

present(value) if {
  is_object(value)
  count(value) > 0
}

approval_paths := {
  "MX": {
    "id": "MX-LOCAL-PRIVACY-SECURITY",
    "jurisdiction": "Mexico",
    "steps": [
      "Local API owner",
      "Mexico Privacy and Legal",
      "Group Security Architecture Board",
    ],
  },
  "BR": {
    "id": "BR-LOCAL-DPO-SECURITY",
    "jurisdiction": "Brazil",
    "steps": [
      "Local API owner",
      "Brazil Data Protection Officer",
      "Group Security Architecture Board",
    ],
  },
  "GROUP": {
    "id": "GROUP-ARCHITECTURE",
    "jurisdiction": "Regional group",
    "steps": [
      "Group API platform owner",
      "Group Security Architecture Board",
    ],
  },
}

expected_residency := {
  "MX": "MX",
  "BR": "BR",
  "GROUP": "MULTI",
}

expected_regulatory_profile := {
  "MX": "MX-LFPDPPP-IFT",
  "BR": "BR-LGPD-ANPD",
  "GROUP": "GROUP-BASELINE",
}

approval_path := object.get(
  approval_paths,
  country,
  {
    "id": "UNRESOLVED",
    "jurisdiction": object.get(input, "country", "unknown"),
    "steps": ["Central policy review required"],
  },
)

commercial := object.get(input, "commercial", {})
local_owner := object.get(input, "localOwner", {})
evidence := object.get(input, "evidence", {})

blocking contains {
  "code": "GROUP_POLICY_VERSION_REQUIRED",
  "policy": "mandatory-group-policy",
  "message": sprintf("Production APIs must declare groupPolicyVersion=%s.", [group_policy_version]),
} if {
  production
  object.get(input, "groupPolicyVersion", "") != group_policy_version
}

blocking contains {
  "code": "COUNTRY_OVERLAY_REQUIRED",
  "policy": "mandatory-country-overlay",
  "message": "Production APIs must select MX, BR or GROUP as the policy overlay.",
} if {
  production
  not country in {"MX", "BR", "GROUP"}
}

blocking contains {
  "code": "RISK_CLASSIFICATION_REQUIRED",
  "policy": "mandatory-risk-classification",
  "message": "Production APIs must declare LOW, MEDIUM, HIGH or CRITICAL risk.",
} if {
  production
  not risk in {"LOW", "MEDIUM", "HIGH", "CRITICAL"}
}

blocking contains {
  "code": "DATA_RESIDENCY_REQUIRED",
  "policy": "mandatory-data-residency",
  "message": "Production APIs must declare a dataResidency label.",
} if {
  production
  not present(object.get(input, "dataResidency", ""))
}

blocking contains {
  "code": "DATA_RESIDENCY_MISMATCH",
  "policy": "country-data-residency",
  "message": sprintf(
    "The %s overlay requires dataResidency=%s.",
    [country, object.get(expected_residency, country, "UNRESOLVED")],
  ),
} if {
  production
  country in {"MX", "BR", "GROUP"}
  data_residency != object.get(expected_residency, country, "")
}

blocking contains {
  "code": "LOCAL_OWNER_NAME_REQUIRED",
  "policy": "mandatory-local-owner",
  "message": "Production APIs must declare localOwner.name.",
} if {
  production
  not present(object.get(local_owner, "name", ""))
}

blocking contains {
  "code": "LOCAL_OWNER_EMAIL_REQUIRED",
  "policy": "mandatory-local-owner",
  "message": "Production APIs must declare localOwner.email.",
} if {
  production
  not present(object.get(local_owner, "email", ""))
}

blocking contains {
  "code": "COMMERCIAL_PLAN_REQUIRED",
  "policy": "mandatory-commercial-metadata",
  "message": "Production APIs must declare commercial.planId.",
} if {
  production
  not present(object.get(commercial, "planId", ""))
}

blocking contains {
  "code": "COMMERCIAL_BILLING_MODEL_REQUIRED",
  "policy": "mandatory-commercial-metadata",
  "message": "Production APIs must declare commercial.billingModel.",
} if {
  production
  not present(object.get(commercial, "billingModel", ""))
}

blocking contains {
  "code": "COMMERCIAL_CURRENCY_REQUIRED",
  "policy": "mandatory-commercial-metadata",
  "message": "Production APIs must declare commercial.currency.",
} if {
  production
  not present(object.get(commercial, "currency", ""))
}

blocking contains {
  "code": "COMMERCIAL_SUBSCRIPTION_POLICY_REQUIRED",
  "policy": "mandatory-commercial-metadata",
  "message": "Production APIs must declare commercial.subscriptionPolicy.",
} if {
  production
  not present(object.get(commercial, "subscriptionPolicy", ""))
}

blocking contains {
  "code": "COMMERCIAL_SLA_TIER_REQUIRED",
  "policy": "mandatory-commercial-metadata",
  "message": "Production APIs must declare commercial.slaTier.",
} if {
  production
  not present(object.get(commercial, "slaTier", ""))
}

blocking contains {
  "code": "REGULATORY_PROFILE_MISMATCH",
  "policy": "country-regulatory-profile",
  "message": sprintf(
    "The %s overlay requires regulatoryProfile=%s.",
    [country, object.get(expected_regulatory_profile, country, "UNRESOLVED")],
  ),
} if {
  production
  country in {"MX", "BR", "GROUP"}
  upper(object.get(input, "regulatoryProfile", "")) != object.get(expected_regulatory_profile, country, "")
}

blocking contains {
  "code": "APPROVAL_PATH_MISMATCH",
  "policy": "country-approval-path",
  "message": sprintf(
    "The %s overlay requires approvalPathId=%s.",
    [country, object.get(approval_path, "id", "UNRESOLVED")],
  ),
} if {
  production
  country in {"MX", "BR", "GROUP"}
  upper(object.get(input, "approvalPathId", "")) != object.get(approval_path, "id", "")
}

blocking contains {
  "code": "HIGH_RISK_SECURITY_REVIEW_REQUIRED",
  "policy": "high-risk-api-classification",
  "message": "HIGH and CRITICAL APIs require evidence.securityReviewId.",
} if {
  production
  high_risk
  not present(object.get(evidence, "securityReviewId", ""))
}

blocking contains {
  "code": "HIGH_RISK_PRIVACY_ASSESSMENT_REQUIRED",
  "policy": "high-risk-api-classification",
  "message": "HIGH and CRITICAL APIs require evidence.privacyImpactAssessmentId.",
} if {
  production
  high_risk
  not present(object.get(evidence, "privacyImpactAssessmentId", ""))
}

blocking contains {
  "code": "HIGH_RISK_APPROVAL_EVIDENCE_REQUIRED",
  "policy": "high-risk-api-classification",
  "message": "HIGH and CRITICAL APIs require evidence.approvalEvidenceId.",
} if {
  production
  high_risk
  not present(object.get(evidence, "approvalEvidenceId", ""))
}

advisories contains {
  "code": "NON_PRODUCTION_POLICY_PREVIEW",
  "policy": "advisory-lifecycle",
  "message": "The descriptor is not PRODUCTION; findings are a non-blocking preview.",
} if {
  not production
}

advisories contains {
  "code": "CONSENT_GUIDANCE_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish purpose, consent or legal-basis guidance for consumers.",
} if {
  object.get(evidence, "consentGuidance", false) != true
}

advisories contains {
  "code": "ERROR_CATALOGUE_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish normalized error examples and correlation guidance.",
} if {
  object.get(evidence, "errorCatalogue", false) != true
}

advisories contains {
  "code": "SLA_GUIDANCE_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish SLA, timeout, retry and support guidance.",
} if {
  object.get(evidence, "slaGuidance", false) != true
}

advisories contains {
  "code": "SANDBOX_DATA_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish sandbox values that exercise allow, deny and advisory decisions.",
} if {
  object.get(evidence, "sandboxData", false) != true
}

advisories contains {
  "code": "POSTMAN_COLLECTION_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish a Postman collection derived from the managed API contract.",
} if {
  object.get(evidence, "postmanCollection", false) != true
}

advisories contains {
  "code": "SDK_INSTRUCTIONS_RECOMMENDED",
  "policy": "developer-experience-advisory",
  "message": "Publish APIM SDK generation and client integration instructions.",
} if {
  object.get(evidence, "sdkInstructions", false) != true
}

advisories contains {
  "code": "APPROVAL_EVIDENCE_URL_RECOMMENDED",
  "policy": "audit-evidence-advisory",
  "message": "Link the approval evidence record used by the local and group approvers.",
} if {
  not present(object.get(evidence, "approvalEvidenceUrl", ""))
}

decision := {
  "allow": count(blocking) == 0,
  "decisionStatus": decision_status,
  "enforcement": {
    "blockingMode": "SELECTED_PRODUCTION_POLICIES",
    "advisoryMode": "REPORT_ONLY",
  },
  "policyVersion": policy_version,
  "groupPolicyVersion": group_policy_version,
  "apiName": object.get(input, "apiName", "unknown"),
  "apiVersion": object.get(input, "apiVersion", "unknown"),
  "lifecycle": upper(object.get(input, "lifecycle", "UNKNOWN")),
  "country": country,
  "riskClassification": risk,
  "highRisk": high_risk,
  "dataResidency": object.get(input, "dataResidency", ""),
  "localOwner": local_owner,
  "commercial": commercial,
  "regulatoryProfile": object.get(input, "regulatoryProfile", ""),
  "approvalPath": approval_path,
  "blocking": [finding | blocking[finding]],
  "advisories": [finding | advisories[finding]],
  "partialResponse": count(advisories) > 0,
}

decision_status := "DENY" if count(blocking) > 0

decision_status := "ALLOW_WITH_ADVISORIES" if {
  count(blocking) == 0
  count(advisories) > 0
}

decision_status := "ALLOW" if {
  count(blocking) == 0
  count(advisories) == 0
}
REGO

log "Writing governed production descriptors."

cat > artifacts/apim-admin/central-policy-catalog.json <<'JSON'
{
  "policyVersion": "2026.07.1",
  "groupPolicyVersion": "TELCO-GROUP-2026.1",
  "descriptors": [
    {
      "apiName": "CentralPolicyDecisionAPI",
      "apiVersion": "1.0.0",
      "lifecycle": "PRODUCTION",
      "country": "GROUP",
      "groupPolicyVersion": "TELCO-GROUP-2026.1",
      "riskClassification": "MEDIUM",
      "dataResidency": "MULTI",
      "localOwner": {
        "name": "Group API Platform Governance",
        "email": "api-governance@example.com"
      },
      "regulatoryProfile": "GROUP-BASELINE",
      "approvalPathId": "GROUP-ARCHITECTURE",
      "commercial": {
        "planId": "TelcoPartnerPremium",
        "billingModel": "INTERNAL_GOVERNANCE_AND_PARTNER_TIER",
        "currency": "USD",
        "subscriptionPolicy": "TelcoPartnerPremium",
        "slaTier": "PREMIUM"
      },
      "evidence": {
        "consentGuidance": true,
        "errorCatalogue": true,
        "slaGuidance": true,
        "sandboxData": true,
        "postmanCollection": true,
        "sdkInstructions": true,
        "approvalEvidenceId": "GROUP-ARCH-2026-071",
        "approvalEvidenceUrl": "https://governance.example.com/evidence/GROUP-ARCH-2026-071"
      }
    },
    {
      "apiName": "OpenGatewaySimSwapRiskAPI",
      "apiVersion": "1.0.0",
      "lifecycle": "PRODUCTION",
      "country": "MX",
      "groupPolicyVersion": "TELCO-GROUP-2026.1",
      "riskClassification": "HIGH",
      "dataResidency": "MX",
      "localOwner": {
        "name": "Mexico Open Gateway Product Owner",
        "email": "mx-open-gateway-owner@example.com"
      },
      "regulatoryProfile": "MX-LFPDPPP-IFT",
      "approvalPathId": "MX-LOCAL-PRIVACY-SECURITY",
      "commercial": {
        "planId": "TelcoOpenGatewayTrustPremium",
        "billingModel": "USAGE_AND_REVENUE_SHARE",
        "currency": "MXN",
        "subscriptionPolicy": "TelcoOpenGatewayTrustPremium",
        "slaTier": "PREMIUM"
      },
      "evidence": {
        "securityReviewId": "MX-SEC-2026-041",
        "privacyImpactAssessmentId": "MX-PIA-2026-019",
        "approvalEvidenceId": "MX-APPROVAL-2026-071",
        "approvalEvidenceUrl": "https://governance.example.com/evidence/MX-APPROVAL-2026-071",
        "consentGuidance": true,
        "errorCatalogue": true,
        "slaGuidance": true,
        "sandboxData": true,
        "postmanCollection": true,
        "sdkInstructions": true
      }
    },
    {
      "apiName": "SecureMobileTransactionsCommercialAPI",
      "apiVersion": "1.0.0",
      "lifecycle": "PRODUCTION",
      "country": "BR",
      "groupPolicyVersion": "TELCO-GROUP-2026.1",
      "riskClassification": "CRITICAL",
      "dataResidency": "BR",
      "localOwner": {
        "name": "Brazil Secure Mobile Transactions Owner",
        "email": "br-secure-mobile-owner@example.com"
      },
      "regulatoryProfile": "BR-LGPD-ANPD",
      "approvalPathId": "BR-LOCAL-DPO-SECURITY",
      "commercial": {
        "planId": "SecureMobileEnterprise",
        "billingModel": "COMMITMENT_PLUS_OUTCOME_OVERAGE",
        "currency": "BRL",
        "subscriptionPolicy": "SecureMobileEnterprise",
        "slaTier": "ENTERPRISE_24X7"
      },
      "evidence": {
        "securityReviewId": "BR-SEC-2026-033",
        "privacyImpactAssessmentId": "BR-RIPD-2026-014",
        "approvalEvidenceId": "BR-APPROVAL-2026-058",
        "approvalEvidenceUrl": "https://governance.example.com/evidence/BR-APPROVAL-2026-058",
        "consentGuidance": true,
        "errorCatalogue": true,
        "slaGuidance": true,
        "sandboxData": true,
        "postmanCollection": true,
        "sdkInstructions": true
      }
    }
  ]
}
JSON

log "Writing the managed OpenAPI contract."

cat > contracts/openapi/central-policy-decision.openapi.yaml <<'YAML'
openapi: 3.0.3
info:
  title: Central Policy Decision API
  version: 1.0.0
  description: |
    Managed WSO2 API Manager facade for the WSO2 Integrator: MI policy-decision
    service. MI preserves correlation identifiers, wraps the request for OPA,
    uses bounded failover between two OPA runtimes and returns blocking and
    advisory findings separately.
  contact:
    name: Group API Platform Governance
    email: api-governance@example.com
servers:
  - url: https://localhost:8243/central-policy-decision/v1/1.0.0
x-wso2-basePath: /central-policy-decision/v1
x-wso2-transports:
  - https
x-telco-api-product: Central Policy Governance Product
x-telco-health-path: /health
x-telco-health-method: GET
tags:
  - name: Central Policy
paths:
  /health:
    get:
      tags: [Central Policy]
      summary: Check the managed MI policy service
      operationId: getCentralPolicyHealth
      security:
        - OAuth2:
            - central-policy:read
      parameters:
        - $ref: '#/components/parameters/CorrelationId'
      responses:
        '200':
          description: Policy mediation service is available
          headers:
            X-Correlation-ID:
              $ref: '#/components/headers/CorrelationId'
          content:
            application/json:
              schema:
                type: object
                required: [status, service, runtime, correlationId]
                properties:
                  status:
                    type: string
                    example: UP
                  service:
                    type: string
                    example: CentralPolicyDecisionAPI
                  runtime:
                    type: string
                    example: WSO2 Integrator MI 4.6.0
                  correlationId:
                    type: string
        '503':
          $ref: '#/components/responses/NormalizedUnavailable'
  /decisions:
    post:
      tags: [Central Policy]
      summary: Evaluate group and country policy overlays
      operationId: evaluateCentralPolicy
      security:
        - OAuth2:
            - central-policy:evaluate
      parameters:
        - $ref: '#/components/parameters/CorrelationId'
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/PolicyDescriptor'
            examples:
              mexicoHighRisk:
                summary: Compliant Mexico high-risk API
                value:
                  apiName: OpenGatewaySimSwapRiskAPI
                  apiVersion: 1.0.0
                  lifecycle: PRODUCTION
                  country: MX
                  groupPolicyVersion: TELCO-GROUP-2026.1
                  riskClassification: HIGH
                  dataResidency: MX
                  localOwner:
                    name: Mexico Open Gateway Product Owner
                    email: mx-open-gateway-owner@example.com
                  regulatoryProfile: MX-LFPDPPP-IFT
                  approvalPathId: MX-LOCAL-PRIVACY-SECURITY
                  commercial:
                    planId: TelcoOpenGatewayTrustPremium
                    billingModel: USAGE_AND_REVENUE_SHARE
                    currency: MXN
                    subscriptionPolicy: TelcoOpenGatewayTrustPremium
                    slaTier: PREMIUM
                  evidence:
                    securityReviewId: MX-SEC-2026-041
                    privacyImpactAssessmentId: MX-PIA-2026-019
                    approvalEvidenceId: MX-APPROVAL-2026-071
                    approvalEvidenceUrl: https://governance.example.com/evidence/MX-APPROVAL-2026-071
                    consentGuidance: true
                    errorCatalogue: true
                    slaGuidance: true
                    sandboxData: true
                    postmanCollection: true
                    sdkInstructions: true
      responses:
        '200':
          description: Policy decision was evaluated; allow=false is a valid decision
          headers:
            X-Correlation-ID:
              $ref: '#/components/headers/CorrelationId'
            X-Policy-Decision:
              description: ALLOW, ALLOW_WITH_ADVISORIES or DENY
              schema:
                type: string
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/PolicyDecision'
        '400':
          $ref: '#/components/responses/NormalizedBadRequest'
        '503':
          $ref: '#/components/responses/NormalizedUnavailable'
components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        clientCredentials:
          tokenUrl: https://localhost:9443/oauth2/token
          scopes:
            central-policy:read: Read policy service health and documentation
            central-policy:evaluate: Evaluate policy descriptors
  parameters:
    CorrelationId:
      name: X-Correlation-ID
      in: header
      required: false
      description: End-to-end correlation identifier. MI generates one when omitted.
      schema:
        type: string
        maxLength: 128
  headers:
    CorrelationId:
      description: Preserved or generated end-to-end correlation identifier
      schema:
        type: string
  schemas:
    PolicyDescriptor:
      type: object
      required:
        - apiName
        - apiVersion
        - lifecycle
        - country
        - groupPolicyVersion
        - riskClassification
        - dataResidency
        - localOwner
        - regulatoryProfile
        - approvalPathId
        - commercial
      properties:
        apiName:
          type: string
        apiVersion:
          type: string
        lifecycle:
          type: string
          enum: [DESIGN, DEVELOPMENT, PRODUCTION, DEPRECATED]
        country:
          type: string
          enum: [MX, BR, GROUP]
        groupPolicyVersion:
          type: string
        riskClassification:
          type: string
          enum: [LOW, MEDIUM, HIGH, CRITICAL]
        dataResidency:
          type: string
          enum: [MX, BR, MULTI]
        localOwner:
          type: object
          required: [name, email]
          properties:
            name:
              type: string
            email:
              type: string
              format: email
        regulatoryProfile:
          type: string
        approvalPathId:
          type: string
        commercial:
          type: object
          required: [planId, billingModel, currency, subscriptionPolicy, slaTier]
          properties:
            planId:
              type: string
            billingModel:
              type: string
            currency:
              type: string
              minLength: 3
              maxLength: 3
            subscriptionPolicy:
              type: string
            slaTier:
              type: string
        evidence:
          type: object
          additionalProperties: true
    Finding:
      type: object
      required: [code, policy, message]
      properties:
        code:
          type: string
        policy:
          type: string
        message:
          type: string
    PolicyDecision:
      type: object
      required:
        - allow
        - decisionStatus
        - policyVersion
        - country
        - blocking
        - advisories
        - correlationId
      properties:
        allow:
          type: boolean
        decisionStatus:
          type: string
          enum: [ALLOW, ALLOW_WITH_ADVISORIES, DENY]
        policyVersion:
          type: string
        groupPolicyVersion:
          type: string
        country:
          type: string
        riskClassification:
          type: string
        highRisk:
          type: boolean
        dataResidency:
          type: string
        localOwner:
          type: object
          additionalProperties: true
        commercial:
          type: object
          additionalProperties: true
        regulatoryProfile:
          type: string
        approvalPath:
          type: object
          additionalProperties: true
        blocking:
          type: array
          items:
            $ref: '#/components/schemas/Finding'
        advisories:
          type: array
          items:
            $ref: '#/components/schemas/Finding'
        partialResponse:
          type: boolean
          description: True when the decision is usable but advisory findings are present.
        correlationId:
          type: string
    NormalizedError:
      type: object
      required: [code, message, correlationId, retryable]
      properties:
        code:
          type: string
        message:
          type: string
        correlationId:
          type: string
        retryable:
          type: boolean
        details:
          type: object
          additionalProperties: true
  responses:
    NormalizedBadRequest:
      description: Invalid request
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/NormalizedError'
    NormalizedUnavailable:
      description: Both bounded OPA endpoints were unavailable or invalid
      headers:
        Retry-After:
          schema:
            type: integer
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/NormalizedError'
YAML

cp contracts/openapi/central-policy-decision.openapi.yaml \
  artifacts/contracts/openapi/central-policy-decision.openapi.yaml

log "Writing native WSO2 Integrator: MI artifacts."

cat > services/wso2-mi/synapse-configs/default/endpoints/CentralPolicyOpaFailoverEndpoint.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<endpoint xmlns="http://ws.apache.org/ns/synapse" name="CentralPolicyOpaFailoverEndpoint">
    <failover>
        <endpoint name="CentralPolicyOpaPrimary">
            <http method="post" uri-template="http://opa:8181/v1/data/telco/central_policy/decision">
                <timeout>
                    <duration>3000</duration>
                    <responseAction>fault</responseAction>
                </timeout>
                <suspendOnFailure>
                    <errorCodes>101500,101501,101503,101506,101507,101508,101509,101510</errorCodes>
                    <initialDuration>1000</initialDuration>
                    <progressionFactor>2.0</progressionFactor>
                    <maximumDuration>30000</maximumDuration>
                </suspendOnFailure>
                <markForSuspension>
                    <errorCodes>101504,101505</errorCodes>
                    <retriesBeforeSuspension>1</retriesBeforeSuspension>
                    <retryDelay>250</retryDelay>
                </markForSuspension>
            </http>
        </endpoint>
        <endpoint name="CentralPolicyOpaDisasterRecovery">
            <http method="post" uri-template="http://opa-dr:8181/v1/data/telco/central_policy/decision">
                <timeout>
                    <duration>3000</duration>
                    <responseAction>fault</responseAction>
                </timeout>
                <suspendOnFailure>
                    <errorCodes>101500,101501,101503,101506,101507,101508,101509,101510</errorCodes>
                    <initialDuration>1000</initialDuration>
                    <progressionFactor>2.0</progressionFactor>
                    <maximumDuration>30000</maximumDuration>
                </suspendOnFailure>
                <markForSuspension>
                    <errorCodes>101504,101505</errorCodes>
                    <retriesBeforeSuspension>1</retriesBeforeSuspension>
                    <retryDelay>250</retryDelay>
                </markForSuspension>
                <retryConfig>
                    <disabledErrorCodes>101500,101501,101503,101504,101505,101506,101507,101508,101509,101510</disabledErrorCodes>
                </retryConfig>
            </http>
        </endpoint>
    </failover>
</endpoint>
XML

cat > services/wso2-mi/synapse-configs/default/sequences/CentralPolicyFaultSequence.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse" name="CentralPolicyFaultSequence">
    <property name="HTTP_SC" value="503" scope="axis2" type="STRING"/>
    <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
    <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
    <property name="Retry-After" value="2" scope="transport" type="STRING"/>
    <property name="X-Correlation-ID"
              expression="get-property('correlation.id')"
              scope="transport"
              type="STRING"/>
    <payloadFactory media-type="json" template-type="default">
        <format>{
          "code": "CENTRAL_POLICY_UPSTREAM_UNAVAILABLE",
          "message": "The central policy decision service could not obtain a valid response from either bounded OPA endpoint.",
          "correlationId": "$1",
          "retryable": true,
          "details": {
            "synapseErrorCode": "$2",
            "synapseErrorMessage": "$3"
          }
        }</format>
        <args>
            <arg expression="get-property('correlation.id')"/>
            <arg expression="get-property('ERROR_CODE')"/>
            <arg expression="get-property('ERROR_MESSAGE')"/>
        </args>
    </payloadFactory>
    <respond/>
</sequence>
XML

cat > services/wso2-mi/synapse-configs/default/api/CentralPolicyDecisionAPI.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<api xmlns="http://ws.apache.org/ns/synapse"
     name="CentralPolicyDecisionAPI"
     context="/internal/central-policy/v1">
    <resource methods="GET" uri-template="/health">
        <inSequence>
            <sequence key="InitializeCorrelationSequence"/>
            <payloadFactory media-type="json" template-type="default">
                <format>{
                  "status": "UP",
                  "service": "CentralPolicyDecisionAPI",
                  "runtime": "WSO2 Integrator: MI 4.6.0",
                  "opaFailover": true,
                  "boundedRetry": true,
                  "partialResponse": "advisories remain non-blocking",
                  "correlationId": "$1"
                }</format>
                <args>
                    <arg expression="get-property('correlation.id')"/>
                </args>
            </payloadFactory>
            <property name="HTTP_SC" value="200" scope="axis2" type="STRING"/>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
            <respond/>
        </inSequence>
        <faultSequence>
            <sequence key="CentralPolicyFaultSequence"/>
        </faultSequence>
    </resource>

    <resource methods="POST" uri-template="/decisions">
        <inSequence>
            <sequence key="InitializeCorrelationSequence"/>
            <log level="custom">
                <property name="event" value="central-policy-evaluation-start"/>
                <property name="correlationId" expression="get-property('correlation.id')"/>
            </log>
            <script language="js"><![CDATA[
                var request = mc.getPayloadJSON();
                var correlationId = String(mc.getProperty('correlation.id') || '');
                if (request == null || typeof request !== 'object' || Array.isArray(request)) {
                    request = {};
                }
                request.correlationId = correlationId;
                mc.setPayloadJSON({ input: request });
            ]]></script>
            <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
            <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
            <header name="X-Correlation-ID"
                    expression="get-property('correlation.id')"
                    scope="transport"/>
            <property name="REST_URL_POSTFIX"
                      scope="axis2"
                      action="remove"/>
            <call blocking="true">
                <endpoint key="CentralPolicyOpaFailoverEndpoint"/>
            </call>
            <script language="js"><![CDATA[
                var envelope = mc.getPayloadJSON();
                var correlationId = String(mc.getProperty('correlation.id') || '');
                if (envelope == null || typeof envelope !== 'object' ||
                    envelope.result == null || typeof envelope.result !== 'object') {
                    mc.setProperty('central.policy.invalid.response', 'true');
                } else {
                    var decision = envelope.result;
                    decision.correlationId = correlationId;
                    decision.partialResponse =
                        Array.isArray(decision.advisories) && decision.advisories.length > 0;
                    mc.setProperty(
                        'central.policy.decision.status',
                        String(decision.decisionStatus || (decision.allow ? 'ALLOW' : 'DENY'))
                    );
                    mc.setPayloadJSON(decision);
                }
            ]]></script>
            <log level="custom">
                <property name="event" value="central-policy-evaluation-complete"/>
                <property name="correlationId" expression="get-property('correlation.id')"/>
                <property name="decisionStatus" expression="get-property('central.policy.decision.status')"/>
            </log>
            <filter source="get-property('central.policy.invalid.response')" regex="true">
                <then>
                    <property name="ERROR_CODE" value="CENTRAL_POLICY_INVALID_RESPONSE"/>
                    <property name="ERROR_MESSAGE" value="OPA returned a response without a result object."/>
                    <sequence key="CentralPolicyFaultSequence"/>
                </then>
                <else>
                    <property name="HTTP_SC" value="200" scope="axis2" type="STRING"/>
                    <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
                    <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
                    <header name="X-Correlation-ID"
                            expression="get-property('correlation.id')"
                            scope="transport"/>
                    <header name="X-Policy-Decision"
                            expression="get-property('central.policy.decision.status')"
                            scope="transport"/>
                    <respond/>
                </else>
            </filter>
        </inSequence>
        <faultSequence>
            <sequence key="CentralPolicyFaultSequence"/>
        </faultSequence>
    </resource>
</api>
XML

log "Writing Docker Compose health and ordering overlay."

cat > docker-compose.central-policy.yml <<'YAML'
services:
  opa:
    healthcheck:
      test:
        - CMD
        - /opa
        - eval
        - --fail
        - --format=discard
        - --data
        - /policies
        - data.telco.central_policy.health
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 5s

  opa-dr:
    image: openpolicyagent/opa:latest
    container_name: telco-opa-dr
    command:
      - run
      - --server
      - --addr=0.0.0.0:8181
      - /policies
    volumes:
      - ./artifacts/opa:/policies:ro
    healthcheck:
      test:
        - CMD
        - /opa
        - eval
        - --fail
        - --format=discard
        - --data
        - /policies
        - data.telco.central_policy.health
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 5s
    restart: unless-stopped

  wso2-mi:
    environment:
      central_policy_opa_primary_url: http://opa:8181/v1/data/telco/central_policy/decision
      central_policy_opa_dr_url: http://opa-dr:8181/v1/data/telco/central_policy/decision
      central_policy_timeout_ms: "3000"
    depends_on:
      subscriber-crm:
        condition: service_healthy
      sim-swap-service:
        condition: service_healthy
      device-location-service:
        condition: service_healthy
      oss-network-service:
        condition: service_healthy
      wso2-apim:
        condition: service_started
      opa:
        condition: service_healthy
      opa-dr:
        condition: service_healthy

  apim-bootstrapper:
    environment:
      OPA_FAIL_ON_DENY: "false"
      CENTRAL_POLICY_FAIL_ON_DENY: "true"
      CENTRAL_POLICY_CATALOG_FILE: /workspace/artifacts/apim-admin/central-policy-catalog.json
      CENTRAL_POLICY_OPA_URL: http://opa:8181/v1/data/telco/central_policy/decision
      CENTRAL_POLICY_MI_URL: http://wso2-mi:8290/internal/central-policy/v1
    depends_on:
      wso2-apim:
        condition: service_started
      telco-backend:
        condition: service_started
      opa:
        condition: service_healthy
      opa-dr:
        condition: service_healthy
      wso2-mi:
        condition: service_healthy
YAML

log "Writing the blocking central-policy preflight."

cat > services/apim-bootstrapper/src/central-policy-preflight.js <<'JS'
'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const OPA_URL =
  process.env.CENTRAL_POLICY_OPA_URL ||
  'http://opa:8181/v1/data/telco/central_policy/decision';
const CATALOG_FILE =
  process.env.CENTRAL_POLICY_CATALOG_FILE ||
  '/workspace/artifacts/apim-admin/central-policy-catalog.json';
const STATE_FILE =
  process.env.CENTRAL_POLICY_PREFLIGHT_STATE_FILE ||
  '/workspace/state/central-policy-preflight.json';
const FAIL_ON_DENY =
  String(process.env.CENTRAL_POLICY_FAIL_ON_DENY || 'true').toLowerCase() === 'true';

function log(message) {
  console.log(`[Central Policy Preflight] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function requestDecision(descriptor) {
  let lastError;
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    try {
      const response = await fetch(OPA_URL, {
        method: 'POST',
        dispatcher,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ input: descriptor }),
        signal: AbortSignal.timeout(5000),
      });
      const text = await response.text();
      let payload;
      try {
        payload = text ? JSON.parse(text) : null;
      } catch {
        payload = null;
      }
      if (!response.ok || !payload?.result) {
        throw new Error(`HTTP ${response.status}: ${text}`);
      }
      return payload.result;
    } catch (error) {
      lastError = error;
      log(
        `Waiting for OPA decision endpoint for ${descriptor.apiName} ` +
          `(${attempt}/30): ${error.message}`,
      );
      await sleep(2000);
    }
  }
  throw new Error(
    `OPA decision endpoint unavailable for ${descriptor.apiName}: ` +
      `${lastError?.message || 'unknown error'}`,
  );
}

async function main() {
  if (!fs.existsSync(CATALOG_FILE)) {
    throw new Error(`Central policy catalog is missing: ${CATALOG_FILE}`);
  }
  const catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
  if (!Array.isArray(catalog.descriptors) || catalog.descriptors.length === 0) {
    throw new Error('Central policy catalog contains no descriptors.');
  }

  const state = {
    status: 'READY',
    generatedAt: new Date().toISOString(),
    failOnDeny: FAIL_ON_DENY,
    policyVersion: catalog.policyVersion,
    groupPolicyVersion: catalog.groupPolicyVersion,
    decisions: [],
  };

  for (const descriptor of catalog.descriptors) {
    const decision = await requestDecision(descriptor);
    const blocking = Array.isArray(decision.blocking) ? decision.blocking : [];
    const advisories = Array.isArray(decision.advisories)
      ? decision.advisories
      : [];
    log(
      `${descriptor.apiName}: ${decision.decisionStatus}; ` +
        `blocking=${blocking.length}; advisories=${advisories.length}`,
    );
    for (const advisory of advisories) {
      log(
        `ADVISORY ${descriptor.apiName} ${advisory.code}: ` +
          `${advisory.message}`,
      );
    }
    state.decisions.push({
      apiName: descriptor.apiName,
      country: descriptor.country,
      riskClassification: descriptor.riskClassification,
      allow: Boolean(decision.allow),
      decisionStatus: decision.decisionStatus,
      blockingCount: blocking.length,
      advisoryCount: advisories.length,
      blocking,
      advisories,
    });
    if (!decision.allow && FAIL_ON_DENY) {
      throw new Error(
        `Blocking central-policy denial for ${descriptor.apiName}: ` +
          blocking.map(item => `${item.code}: ${item.message}`).join('; '),
      );
    }
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);
  log(
    `READY: ${state.decisions.length} production descriptors passed the ` +
      `blocking gate; advisory findings remained report-only.`,
  );
}

main().catch(error => {
  console.error(
    `[Central Policy Preflight] failed: ${error.stack || error.message}`,
  );
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(
      STATE_FILE,
      `${JSON.stringify(
        {
          status: 'FAILED',
          generatedAt: new Date().toISOString(),
          failOnDeny: FAIL_ON_DENY,
          error: error.message,
        },
        null,
        2,
      )}\n`,
    );
  } catch {
    // Preserve the original error.
  }
  process.exit(1);
});
JS

log "Writing APIM central-policy enrichment and blocking-gate bootstrap."

cat > services/apim-bootstrapper/src/central-policy-setup.js <<'JS'
'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, FormData, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const OPA_URL =
  process.env.CENTRAL_POLICY_OPA_URL ||
  'http://opa:8181/v1/data/telco/central_policy/decision';
const CATALOG_FILE =
  process.env.CENTRAL_POLICY_CATALOG_FILE ||
  '/workspace/artifacts/apim-admin/central-policy-catalog.json';
const STATE_FILE =
  process.env.CENTRAL_POLICY_STATE_FILE ||
  '/workspace/state/central-policy.json';
const FAIL_ON_DENY =
  String(process.env.CENTRAL_POLICY_FAIL_ON_DENY || 'true').toLowerCase() === 'true';
const PRODUCT_NAME = 'CentralPolicyGovernanceProduct';

function log(message) {
  console.log(`[Central Policy] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function request(
  url,
  {
    method = 'GET',
    bearer,
    basic,
    json,
    body,
    headers = {},
    ok = [200, 201, 202, 204],
  } = {},
) {
  const requestHeaders = { ...headers };
  if (bearer) requestHeaders.Authorization = `Bearer ${bearer}`;
  if (basic) {
    requestHeaders.Authorization =
      `Basic ${Buffer.from(basic).toString('base64')}`;
  }
  if (json !== undefined) {
    requestHeaders['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  }
  const response = await fetch(url, {
    method,
    headers: requestHeaders,
    body,
    dispatcher,
  });
  const text = await response.text();
  let data = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!ok.includes(response.status)) {
    const rendered =
      typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    throw new Error(`${method} ${url} -> HTTP ${response.status}: ${rendered}`);
  }
  return data;
}

async function waitFor(url, label, attempts = 90) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, { dispatcher });
      if (response.ok) {
        log(`${label} is reachable.`);
        return;
      }
    } catch {
      // Service may still be starting.
    }
    log(`Waiting for ${label} (${attempt}/${attempts})`);
    await sleep(2000);
  }
  throw new Error(`${label} did not become reachable at ${url}`);
}

async function getPublisherToken() {
  const dcr = await request(
    `${APIM_URL}/client-registration/v0.17/register`,
    {
      method: 'POST',
      basic: `${USERNAME}:${PASSWORD}`,
      json: {
        callbackUrl: 'http://localhost:8080/callback',
        clientName: `telco-central-policy-${Date.now()}`,
        owner: USERNAME,
        grantType: 'password refresh_token client_credentials',
        saasApp: true,
      },
      ok: [200, 201],
    },
  );
  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    [
      'apim:api_view',
      'apim:api_create',
      'apim:api_update',
      'apim:api_manage',
      'apim:api_publish',
      'apim:api_metadata_view',
      'service_catalog:service_view',
      'service_catalog:service_write',
    ].join(' '),
  );
  const token = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.clientId}:${dcr.clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
    ok: [200],
  });
  if (!token.access_token) throw new Error('Publisher token was not returned.');
  return token.access_token;
}

async function listApis(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/apis?limit=1000`,
    { bearer: token },
  );
  return Array.isArray(response) ? response : response.list || response.data || [];
}

async function listProducts(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products?limit=1000`,
    { bearer: token },
  );
  return Array.isArray(response) ? response : response.list || response.data || [];
}

function upsertProperties(entity, properties) {
  const byName = new Map();
  for (const property of Array.isArray(entity.additionalProperties)
    ? entity.additionalProperties
    : []) {
    if (property && property.name) {
      byName.set(String(property.name).toLowerCase(), {
        name: String(property.name),
        value: String(property.value ?? ''),
        display: property.display !== false,
      });
    }
  }
  for (const [name, value] of Object.entries(properties)) {
    byName.set(name.toLowerCase(), {
      name,
      value: String(value ?? ''),
      display: true,
    });
  }
  entity.additionalProperties = Array.from(byName.values());
}

function plansFor(apiName, descriptor) {
  if (apiName === 'OpenGatewaySimSwapRiskAPI') {
    return [
      'TelcoFreeTrial',
      'TelcoOpenGatewayTrustStarter',
      'TelcoOpenGatewayTrustPremium',
      'Unlimited',
    ];
  }
  if (apiName === 'SecureMobileTransactionsCommercialAPI') {
    return [
      'SecureMobileSandbox',
      'SecureMobileBusiness',
      'SecureMobileEnterprise',
      'Unlimited',
    ];
  }
  return ['TelcoPartnerStandard', 'TelcoPartnerPremium', 'Unlimited'];
}

function descriptorProperties(descriptor, decision) {
  return {
    CentralPolicyVersion: decision.policyVersion,
    GroupPolicyVersion: descriptor.groupPolicyVersion,
    CountryOverlay: descriptor.country,
    RiskClassification: descriptor.riskClassification,
    HighRiskAPI: String(Boolean(decision.highRisk)),
    DataResidency: descriptor.dataResidency,
    LocalOwner: descriptor.localOwner.name,
    LocalOwnerEmail: descriptor.localOwner.email,
    RegulatoryProfile: descriptor.regulatoryProfile,
    ApprovalPathId: descriptor.approvalPathId,
    ApprovalPath:
      Array.isArray(decision.approvalPath?.steps)
        ? decision.approvalPath.steps.join(' -> ')
        : '',
    CommercialPlanId: descriptor.commercial.planId,
    CommercialBillingModel: descriptor.commercial.billingModel,
    CommercialCurrency: descriptor.commercial.currency,
    CommercialSubscriptionPolicy: descriptor.commercial.subscriptionPolicy,
    CommercialSlaTier: descriptor.commercial.slaTier,
    CentralPolicyEnforcement: 'BLOCKING_PRODUCTION_AND_ADVISORY_REPORT_ONLY',
    PolicyDecision: decision.decisionStatus,
    PolicyAdvisoryCount: Array.isArray(decision.advisories)
      ? decision.advisories.length
      : 0,
  };
}

async function evaluateDescriptor(descriptor) {
  const response = await request(OPA_URL, {
    method: 'POST',
    json: { input: descriptor },
    ok: [200],
  });
  const decision = response?.result;
  if (!decision || typeof decision !== 'object') {
    throw new Error(`OPA returned no result for ${descriptor.apiName}.`);
  }
  const blocking = Array.isArray(decision.blocking) ? decision.blocking : [];
  const advisories = Array.isArray(decision.advisories)
    ? decision.advisories
    : [];
  log(
    `${descriptor.apiName}: ${decision.decisionStatus}; ` +
      `blocking=${blocking.length}; advisories=${advisories.length}`,
  );
  for (const advisory of advisories) {
    log(`ADVISORY ${descriptor.apiName} ${advisory.code}: ${advisory.message}`);
  }
  if (!decision.allow && FAIL_ON_DENY) {
    throw new Error(
      `Blocking central-policy denial for ${descriptor.apiName}: ` +
        blocking.map(item => `${item.code}: ${item.message}`).join('; '),
    );
  }
  return decision;
}

function documentContent(descriptor, decision, kind) {
  const approvalSteps =
    Array.isArray(decision.approvalPath?.steps)
      ? decision.approvalPath.steps.map((step, i) => `${i + 1}. ${step}`).join('\n')
      : '1. Central policy review';
  const common = [
    `API: **${descriptor.apiName}:${descriptor.apiVersion}**`,
    `Country overlay: **${descriptor.country}**`,
    `Risk classification: **${descriptor.riskClassification}**`,
    `Data residency: **${descriptor.dataResidency}**`,
    `Local owner: **${descriptor.localOwner.name}** (${descriptor.localOwner.email})`,
    `Commercial plan: **${descriptor.commercial.planId}**`,
    `Subscription policy: **${descriptor.commercial.subscriptionPolicy}**`,
    `Policy decision: **${decision.decisionStatus}**`,
  ].join('\n\n');

  if (kind === 'overview') {
    return `# Central Policy and Country Overlay

${common}

## Enforcement model

Production rules for group policy version, country overlay, risk classification,
data residency, local ownership, regulatory profile, commercial metadata and
high-risk evidence are blocking. Documentation-quality findings remain advisory
and are returned in the same decision without preventing publication.

## Approval path

${approvalSteps}

Mexico uses local owner → Mexico Privacy and Legal → Group Security Architecture
Board. Brazil uses local owner → Brazil DPO → Group Security Architecture Board.
`;
  }

  if (kind === 'privacy') {
    return `# Consent, Privacy and Data Residency

${common}

Consumers must preserve purpose limitation, consent or another approved legal
basis, data minimization, retention controls and immutable audit evidence.
The declared data-residency label is a deployment and processing constraint,
not merely descriptive metadata.

- Mexico profile: **MX-LFPDPPP-IFT**
- Brazil profile: **BR-LGPD-ANPD**
- Group baseline: **GROUP-BASELINE**

HIGH and CRITICAL APIs require a security review, privacy-impact assessment and
approval evidence before the blocking gate can return allow=true.
`;
  }

  return `# Errors, SLA, Sandbox, Postman and SDK

${common}

## Normalized errors

MI returns \`CENTRAL_POLICY_UPSTREAM_UNAVAILABLE\` with HTTP 503 only when both
bounded OPA endpoints fail or return an invalid envelope. An OPA policy denial
is a successful HTTP 200 decision with \`allow=false\`, a \`DENY\` status and
one or more blocking findings. Preserve \`X-Correlation-ID\` in support cases.

## Resilience and SLA guidance

- OPA request timeout: 3 seconds per endpoint.
- One bounded retry before suspension.
- Primary-to-DR failover.
- Exponential endpoint suspension up to 30 seconds.
- Advisory findings are a valid partial response and remain non-blocking.
- Illustrative premium target: 99.95% with 24x7 incident handling.

## Sandbox data

Use the catalog descriptors for compliant MX, BR and GROUP examples. To test a
blocking decision, remove \`localOwner.email\` or use a residency that does not
match the country. To test advisory behavior, retain all mandatory fields and
set one documentation evidence flag to false.

## Postman and SDK

Import \`artifacts/postman/telco-central-policy-overlays.postman_collection.json\`.
In the Developer Portal, open the API, use Try Out, and generate an SDK from the
published OpenAPI contract. Configure the generated client with the APIM gateway
base URL and an OAuth2 client-credentials token.
`;
}

async function listDocuments(token, basePath) {
  const response = await request(`${APIM_URL}${basePath}?limit=100`, {
    bearer: token,
  });
  return Array.isArray(response) ? response : response.list || response.data || [];
}

async function upsertDocument(token, basePath, document) {
  const existing = await listDocuments(token, basePath);
  let current = existing.find(item => item.name === document.name);
  const metadata = {
    name: document.name,
    summary: document.summary,
    type: document.type,
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL',
  };
  if (current?.documentId || current?.id) {
    const id = current.documentId || current.id;
    current = await request(
      `${APIM_URL}${basePath}/${encodeURIComponent(id)}`,
      {
        method: 'PUT',
        bearer: token,
        json: metadata,
        ok: [200, 201, 202],
      },
    );
  } else {
    current = await request(`${APIM_URL}${basePath}`, {
      method: 'POST',
      bearer: token,
      json: metadata,
      ok: [200, 201, 202],
    });
  }
  const documentId =
    current?.documentId ||
    current?.id ||
    existing.find(item => item.name === document.name)?.documentId;
  if (!documentId) {
    throw new Error(`Document ID was not returned for ${document.name}.`);
  }
  const form = new FormData();
  form.append('inlineContent', document.content);
  await request(
    `${APIM_URL}${basePath}/${encodeURIComponent(documentId)}/content`,
    {
      method: 'POST',
      bearer: token,
      body: form,
      ok: [200, 201, 202],
    },
  );
  log(`upserted document: ${document.name}`);
}

function documentsFor(descriptor, decision) {
  return [
    {
      name: '10 - Central Policy and Country Overlay',
      summary: 'Blocking group policy and local regulatory overlay.',
      type: 'HOWTO',
      content: documentContent(descriptor, decision, 'overview'),
    },
    {
      name: '11 - Consent Privacy and Data Residency',
      summary: 'Country-specific privacy, consent and residency guidance.',
      type: 'HOWTO',
      content: documentContent(descriptor, decision, 'privacy'),
    },
    {
      name: '12 - Errors SLA Sandbox Postman and SDK',
      summary: 'Runtime, resilience, support and consumer tooling.',
      type: 'SAMPLES',
      content: documentContent(descriptor, decision, 'toolkit'),
    },
  ];
}

async function updateApi(token, summary, descriptor, decision) {
  const api = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`,
    { bearer: token },
  );
  api.policies = Array.from(
    new Set([...(Array.isArray(api.policies) ? api.policies : []), ...plansFor(api.name, descriptor)]),
  );
  api.businessInformation = {
    ...(api.businessInformation || {}),
    businessOwner: descriptor.localOwner.name,
    businessOwnerEmail: descriptor.localOwner.email,
    technicalOwner: 'Telco API Platform Team',
    technicalOwnerEmail: 'api-platform@example.com',
  };
  upsertProperties(api, descriptorProperties(descriptor, decision));
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, {
    method: 'PUT',
    bearer: token,
    json: api,
    ok: [200, 201, 202],
  });
  for (const document of documentsFor(descriptor, decision)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/apis/${api.id}/documents`,
      document,
    );
  }
  return {
    id: api.id,
    name: api.name,
    policies: api.policies,
    lifecycle: api.lifeCycleStatus,
  };
}

async function publishProduct(token, product) {
  const state = String(
    product.state || product.lifeCycleStatus || product.status || '',
  ).toUpperCase();
  if (state === 'PUBLISHED') return product;

  let revisionId;
  try {
    const revision = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/revisions`,
      {
        method: 'POST',
        bearer: token,
        json: {
          description:
            'Central policy country-overlay product release with Developer Portal documentation',
        },
        ok: [200, 201, 202],
      },
    );
    revisionId = revision.id || revision.revisionUuid || revision.revisionId;
  } catch (error) {
    log(`Product revision creation was non-fatal: ${error.message}`);
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/revisions`,
      { bearer: token },
    );
    const revisions = Array.isArray(response)
      ? response
      : response.list || response.data || [];
    const latest = revisions[revisions.length - 1];
    revisionId = latest?.id || latest?.revisionUuid || latest?.revisionId;
  }

  if (revisionId) {
    try {
      await request(
        `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/deploy-revision?revisionId=${encodeURIComponent(revisionId)}`,
        {
          method: 'POST',
          bearer: token,
          json: [
            {
              name: 'Default',
              vhost: 'localhost',
              displayOnDevportal: true,
            },
          ],
          ok: [200, 201, 202],
        },
      );
    } catch (error) {
      const message = String(error.message || error).toLowerCase();
      if (
        !message.includes('already deployed') &&
        !message.includes('409') &&
        !message.includes('revision deployment')
      ) {
        throw error;
      }
    }
  }

  try {
    await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/change-lifecycle?apiProductId=${encodeURIComponent(product.id)}&action=Publish`,
      {
        method: 'POST',
        bearer: token,
        ok: [200, 201, 202],
      },
    );
  } catch (error) {
    const message = String(error.message || error).toLowerCase();
    if (
      !message.includes('already') &&
      !message.includes('unsupported state change action') &&
      !message.includes('903234')
    ) {
      throw error;
    }
  }

  return request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    { bearer: token },
  );
}

async function updateProduct(token, productSummary, descriptor, decision) {
  const product = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${productSummary.id}`,
    { bearer: token },
  );
  product.policies = Array.from(
    new Set([
      ...(Array.isArray(product.policies) ? product.policies : []),
      'TelcoPartnerStandard',
      'TelcoPartnerPremium',
      'Unlimited',
    ]),
  );
  upsertProperties(product, {
    ...descriptorProperties(descriptor, decision),
    CountryOverlayCoverage: 'GROUP,MX,BR',
    MemberPolicyAPI: 'CentralPolicyDecisionAPI',
  });
  await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    {
      method: 'PUT',
      bearer: token,
      json: product,
      ok: [200, 201, 202],
    },
  );
  for (const document of documentsFor(descriptor, decision)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/api-products/${product.id}/documents`,
      document,
    );
  }
  const published = await publishProduct(token, product);
  const finalState = String(
    published.state || published.lifeCycleStatus || published.status || '',
  ).toUpperCase();
  if (finalState && finalState !== 'PUBLISHED') {
    throw new Error(`${PRODUCT_NAME} final lifecycle state is ${finalState}.`);
  }
  return { id: product.id, name: product.name, state: finalState || 'PUBLISHED' };
}

function centralPolicyServiceDefinition() {
  return {
    openapi: '3.0.3',
    info: {
      title: 'Central Policy Decision API',
      version: '1.0.0',
      description:
        'MI-managed OPA decision facade with correlation, normalized errors, bounded retry and failover.',
    },
    servers: [
      { url: 'http://wso2-mi:8290/internal/central-policy/v1' },
    ],
    paths: {
      '/health': {
        get: {
          operationId: 'centralPolicyHealth',
          responses: {
            200: {
              description: 'Healthy',
              content: {
                'application/json': {
                  schema: { type: 'object', additionalProperties: true },
                },
              },
            },
          },
        },
      },
      '/decisions': {
        post: {
          operationId: 'evaluateCentralPolicy',
          requestBody: {
            required: true,
            content: {
              'application/json': {
                schema: { type: 'object', additionalProperties: true },
              },
            },
          },
          responses: {
            200: {
              description: 'Evaluated policy decision',
              content: {
                'application/json': {
                  schema: { type: 'object', additionalProperties: true },
                },
              },
            },
            503: { description: 'Both bounded OPA endpoints unavailable' },
          },
        },
      },
    },
  };
}

async function upsertServiceCatalog(token) {
  const metadata = {
    name: 'CentralPolicyDecisionAPI',
    version: '1.0.0',
    description:
      'WSO2 Integrator: MI service that preserves correlation, wraps OPA requests, normalizes decisions and uses bounded retry, failover and endpoint suspension.',
    serviceUrl: 'http://wso2-mi:8290/internal/central-policy/v1',
    definitionType: 'OAS3',
    securityType: 'NONE',
    mutualSSLEnabled: false,
  };
  const response = await request(
    `${APIM_URL}/api/am/service-catalog/v1/services?limit=100`,
    { bearer: token },
  );
  const services = Array.isArray(response)
    ? response
    : response.list || response.data || [];
  const existing = services.find(
    item =>
      item.name === metadata.name &&
      String(item.version || '') === metadata.version,
  );
  const form = new FormData();
  form.append(
    'definitionFile',
    new Blob([JSON.stringify(centralPolicyServiceDefinition(), null, 2)], {
      type: 'application/json',
    }),
    'central-policy-decision-openapi.json',
  );
  form.append(
    'serviceMetadata',
    new Blob([JSON.stringify(metadata, null, 2)], {
      type: 'application/json',
    }),
    'central-policy-decision-metadata.json',
  );
  const id = existing?.id || existing?.serviceId;
  const url = id
    ? `${APIM_URL}/api/am/service-catalog/v1/services/${encodeURIComponent(id)}`
    : `${APIM_URL}/api/am/service-catalog/v1/services`;
  const result = await request(url, {
    method: id ? 'PUT' : 'POST',
    bearer: token,
    body: form,
    ok: [200, 201, 202],
  });
  log(
    `${metadata.name}:${metadata.version} ${id ? 'updated' : 'created'} in APIM Service Catalog.`,
  );
  return {
    id: result?.id || result?.serviceId || id || null,
    name: metadata.name,
    version: metadata.version,
    action: id ? 'UPDATED' : 'CREATED',
  };
}

async function main() {
  if (!fs.existsSync(CATALOG_FILE)) {
    throw new Error(`Central policy catalog is missing: ${CATALOG_FILE}`);
  }
  const catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
  if (!Array.isArray(catalog.descriptors) || catalog.descriptors.length < 3) {
    throw new Error('Central policy catalog must contain GROUP, MX and BR descriptors.');
  }

  await waitFor(`${APIM_URL}/services/Version`, 'WSO2 API Manager');
  await waitFor(
    OPA_URL.replace('/v1/data/telco/central_policy/decision', '/health'),
    'OPA',
    30,
  ).catch(async () => {
    // OPA's root health URL differs by version. The decision call below is authoritative.
    log('OPA root health endpoint was not exposed; continuing to decision evaluation.');
  });

  const decisions = [];
  for (const descriptor of catalog.descriptors) {
    decisions.push({
      descriptor,
      decision: await evaluateDescriptor(descriptor),
    });
  }

  const token = await getPublisherToken();
  const apiSummaries = await listApis(token);
  const productSummaries = await listProducts(token);
  const state = {
    status: 'READY',
    generatedAt: new Date().toISOString(),
    failOnDeny: FAIL_ON_DENY,
    decisions: [],
    apis: [],
    products: [],
    serviceCatalog: null,
  };

  for (const item of decisions) {
    const summary = apiSummaries.find(
      api =>
        api.name === item.descriptor.apiName &&
        String(api.version || '1.0.0') === String(item.descriptor.apiVersion),
    );
    if (!summary?.id) {
      throw new Error(
        `Expected API is absent from Publisher: ` +
          `${item.descriptor.apiName}:${item.descriptor.apiVersion}`,
      );
    }
    state.apis.push(
      await updateApi(token, summary, item.descriptor, item.decision),
    );
    state.decisions.push({
      apiName: item.descriptor.apiName,
      allow: item.decision.allow,
      decisionStatus: item.decision.decisionStatus,
      blockingCount: item.decision.blocking?.length || 0,
      advisoryCount: item.decision.advisories?.length || 0,
      approvalPath: item.decision.approvalPath,
    });
  }

  const central = decisions.find(
    item => item.descriptor.apiName === 'CentralPolicyDecisionAPI',
  );
  const productSummary = productSummaries.find(
    product =>
      product.name === PRODUCT_NAME &&
      String(product.version || '1.0.0') === '1.0.0',
  );
  if (!productSummary?.id) {
    throw new Error(`Expected native API Product is absent: ${PRODUCT_NAME}:1.0.0`);
  }
  state.products.push(
    await updateProduct(
      token,
      productSummary,
      central.descriptor,
      central.decision,
    ),
  );
  state.serviceCatalog = await upsertServiceCatalog(token);

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);
  log(`state written to ${STATE_FILE}`);
  log(
    `completed: ${state.apis.length} governed APIs, ` +
      `${state.products.length} native API Product, ` +
      `${state.decisions.length} blocking/advisory decisions, ` +
      `Service Catalog registered`,
  );
}

main().catch(error => {
  console.error(`[Central Policy] failed: ${error.stack || error.message}`);
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(
      STATE_FILE,
      `${JSON.stringify(
        {
          status: 'FAILED',
          generatedAt: new Date().toISOString(),
          error: error.message,
        },
        null,
        2,
      )}\n`,
    );
  } catch {
    // Preserve the original failure.
  }
  process.exit(1);
});
JS

log "Writing Developer Portal source documentation."

cat > artifacts/developer-experience/central-policy/consumer-guide.md <<'MD'
# Central Policy Consumer Guide

The Central Policy Decision API exposes the same group-wide OPA decision through
WSO2 API Manager while WSO2 Integrator: MI performs correlation, request
wrapping, normalized response handling, timeouts, bounded retries, failover and
endpoint suspension.

A policy denial is returned as HTTP 200 with `allow=false`; it is not a transport
failure. Production descriptors are blocked when mandatory group, country,
risk, residency, ownership, regulatory, approval or commercial metadata is
absent. Documentation maturity remains advisory.
MD

cat > artifacts/developer-experience/central-policy/consent-and-regulatory-guidance.md <<'MD'
# Mexico and Brazil Consent and Regulatory Guidance

Mexico uses the `MX-LFPDPPP-IFT` profile and the approval path:

1. Local API owner
2. Mexico Privacy and Legal
3. Group Security Architecture Board

Brazil uses the `BR-LGPD-ANPD` profile and the approval path:

1. Local API owner
2. Brazil Data Protection Officer
3. Group Security Architecture Board

The data-residency label is enforced by the selected overlay. HIGH and CRITICAL
APIs require security, privacy-impact and approval evidence.
MD

cat > artifacts/developer-experience/central-policy/errors-sla-sandbox-sdk.md <<'MD'
# Errors, SLA, Sandbox, Postman and SDK

- Preserve `X-Correlation-ID`.
- HTTP 200 with `allow=false` is a valid policy denial.
- HTTP 503 `CENTRAL_POLICY_UPSTREAM_UNAVAILABLE` means both OPA endpoints failed.
- MI uses a 3-second timeout, bounded retry, failover and endpoint suspension.
- Advisory findings are a usable partial response.
- Use the descriptors in `central-policy-catalog.json` as sandbox data.
- Import the generated Postman collection.
- Generate client SDKs from the API in the APIM Developer Portal.
MD

log "Writing Postman collection."

cat > artifacts/postman/telco-central-policy-overlays.postman_collection.json <<'JSON'
{
  "info": {
    "_postman_id": "11eef35b-6aa2-4b7c-a1b1-central-policy-overlays",
    "name": "Telco Central Policy Country Overlays",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
    "description": "GROUP, Mexico and Brazil policy-decision examples through APIM."
  },
  "variable": [
    {
      "key": "gatewayBaseUrl",
      "value": "https://localhost:8243/central-policy-decision/v1/1.0.0"
    },
    {
      "key": "accessToken",
      "value": ""
    },
    {
      "key": "correlationId",
      "value": "central-policy-postman-001"
    }
  ],
  "item": [
    {
      "name": "Health",
      "request": {
        "method": "GET",
        "header": [
          {
            "key": "Authorization",
            "value": "Bearer {{accessToken}}"
          },
          {
            "key": "X-Correlation-ID",
            "value": "{{correlationId}}"
          }
        ],
        "url": "{{gatewayBaseUrl}}/health"
      }
    },
    {
      "name": "Mexico high-risk allow",
      "request": {
        "method": "POST",
        "header": [
          {
            "key": "Authorization",
            "value": "Bearer {{accessToken}}"
          },
          {
            "key": "Content-Type",
            "value": "application/json"
          },
          {
            "key": "X-Correlation-ID",
            "value": "{{correlationId}}"
          }
        ],
        "body": {
          "mode": "raw",
          "raw": "{\n  \"apiName\": \"OpenGatewaySimSwapRiskAPI\",\n  \"apiVersion\": \"1.0.0\",\n  \"lifecycle\": \"PRODUCTION\",\n  \"country\": \"MX\",\n  \"groupPolicyVersion\": \"TELCO-GROUP-2026.1\",\n  \"riskClassification\": \"HIGH\",\n  \"dataResidency\": \"MX\",\n  \"localOwner\": {\"name\": \"Mexico Open Gateway Product Owner\", \"email\": \"mx-open-gateway-owner@example.com\"},\n  \"regulatoryProfile\": \"MX-LFPDPPP-IFT\",\n  \"approvalPathId\": \"MX-LOCAL-PRIVACY-SECURITY\",\n  \"commercial\": {\"planId\": \"TelcoOpenGatewayTrustPremium\", \"billingModel\": \"USAGE_AND_REVENUE_SHARE\", \"currency\": \"MXN\", \"subscriptionPolicy\": \"TelcoOpenGatewayTrustPremium\", \"slaTier\": \"PREMIUM\"},\n  \"evidence\": {\"securityReviewId\": \"MX-SEC-2026-041\", \"privacyImpactAssessmentId\": \"MX-PIA-2026-019\", \"approvalEvidenceId\": \"MX-APPROVAL-2026-071\", \"approvalEvidenceUrl\": \"https://governance.example.com/evidence/MX-APPROVAL-2026-071\", \"consentGuidance\": true, \"errorCatalogue\": true, \"slaGuidance\": true, \"sandboxData\": true, \"postmanCollection\": true, \"sdkInstructions\": true}\n}"
        },
        "url": "{{gatewayBaseUrl}}/decisions"
      }
    },
    {
      "name": "Brazil residency deny",
      "request": {
        "method": "POST",
        "header": [
          {
            "key": "Authorization",
            "value": "Bearer {{accessToken}}"
          },
          {
            "key": "Content-Type",
            "value": "application/json"
          },
          {
            "key": "X-Correlation-ID",
            "value": "{{correlationId}}"
          }
        ],
        "body": {
          "mode": "raw",
          "raw": "{\n  \"apiName\": \"SecureMobileTransactionsCommercialAPI\",\n  \"apiVersion\": \"1.0.0\",\n  \"lifecycle\": \"PRODUCTION\",\n  \"country\": \"BR\",\n  \"groupPolicyVersion\": \"TELCO-GROUP-2026.1\",\n  \"riskClassification\": \"CRITICAL\",\n  \"dataResidency\": \"MX\",\n  \"localOwner\": {\"name\": \"Brazil Secure Mobile Transactions Owner\", \"email\": \"br-secure-mobile-owner@example.com\"},\n  \"regulatoryProfile\": \"BR-LGPD-ANPD\",\n  \"approvalPathId\": \"BR-LOCAL-DPO-SECURITY\",\n  \"commercial\": {\"planId\": \"SecureMobileEnterprise\", \"billingModel\": \"COMMITMENT_PLUS_OUTCOME_OVERAGE\", \"currency\": \"BRL\", \"subscriptionPolicy\": \"SecureMobileEnterprise\", \"slaTier\": \"ENTERPRISE_24X7\"},\n  \"evidence\": {\"securityReviewId\": \"BR-SEC-2026-033\", \"privacyImpactAssessmentId\": \"BR-RIPD-2026-014\", \"approvalEvidenceId\": \"BR-APPROVAL-2026-058\"}\n}"
        },
        "url": "{{gatewayBaseUrl}}/decisions"
      }
    }
  ]
}
JSON

log "Patching existing bootstrap conventions idempotently."

python3 <<'PY'
from pathlib import Path
import json
import re

bootstrap = Path("services/apim-bootstrapper/src/bootstrap.js")
text = bootstrap.read_text()

api_marker = "name: 'CentralPolicyDecisionAPI'"
if api_marker not in text:
    anchor = "{ id: 'network-events', name: 'NetworkEventsStreamAPI'"
    if anchor not in text:
        raise SystemExit("Could not locate the network-events API anchor in bootstrap.js.")
    api_object = """{ id: 'central-policy-decision', name: 'CentralPolicyDecisionAPI', version: '1.0.0', importSpecCandidates: [ 'contracts/openapi/central-policy-decision.openapi.yaml', 'central-policy-decision.openapi.yaml' ], context: '/central-policy-decision/v1', endpointUrl: `${MI_BACKEND_URL}/internal/central-policy/v1`, apiProduct: 'Central Policy Governance Product', healthPath: '/health', healthMethod: 'GET', routes: ['/health', '/decisions'] }, """
    text = text.replace(anchor, api_object + anchor, 1)

helper_marker = "async function evaluateCentralPolicyBeforePublish(api)"
if helper_marker not in text:
    anchor = "async function publishApiWithPublisherRest(api) {"
    if anchor not in text:
        raise SystemExit("Could not locate publishApiWithPublisherRest in bootstrap.js.")
    helper = r"""
const CENTRAL_POLICY_CATALOG_FILE = process.env.CENTRAL_POLICY_CATALOG_FILE || '/workspace/artifacts/apim-admin/central-policy-catalog.json';
const CENTRAL_POLICY_OPA_URL = process.env.CENTRAL_POLICY_OPA_URL || 'http://opa:8181/v1/data/telco/central_policy/decision';
const CENTRAL_POLICY_FAIL_ON_DENY = String(process.env.CENTRAL_POLICY_FAIL_ON_DENY || 'true').toLowerCase() === 'true';
function centralPolicyDescriptorFor(api) {
  if (!fs.existsSync(CENTRAL_POLICY_CATALOG_FILE)) return null;
  const catalog = JSON.parse(fs.readFileSync(CENTRAL_POLICY_CATALOG_FILE, 'utf8'));
  return (catalog.descriptors || []).find(
    item => item.apiName === api.name && String(item.apiVersion || '1.0.0') === String(api.version || '1.0.0')
  ) || null;
}
async function evaluateCentralPolicyBeforePublish(api) {
  const descriptor = centralPolicyDescriptorFor(api);
  if (!descriptor) return null;
  const response = await fetch(CENTRAL_POLICY_OPA_URL, {
    method: 'POST',
    dispatcher,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ input: descriptor }),
    signal: AbortSignal.timeout(5000)
  });
  const text = await response.text();
  let payload;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = null; }
  if (!response.ok || !payload?.result) {
    throw new Error(`Central policy gate unavailable for ${api.name}: HTTP ${response.status} ${text}`);
  }
  const decision = payload.result;
  const blocking = Array.isArray(decision.blocking) ? decision.blocking : [];
  const advisories = Array.isArray(decision.advisories) ? decision.advisories : [];
  log(`[central-policy] ${api.name}: ${decision.decisionStatus}; blocking=${blocking.length}; advisories=${advisories.length}`);
  for (const advisory of advisories) {
    log(`[central-policy][advisory] ${api.name} ${advisory.code}: ${advisory.message}`);
  }
  if (!decision.allow && CENTRAL_POLICY_FAIL_ON_DENY) {
    throw new Error(
      `Central policy blocked ${api.name}: ` +
      blocking.map(item => `${item.code}: ${item.message}`).join('; ')
    );
  }
  return decision;
}
"""
    text = text.replace(anchor, helper + "\n" + anchor, 1)

call_marker = "await evaluateCentralPolicyBeforePublish(api);"
if call_marker not in text:
    anchor = "async function publishApiWithPublisherRest(api) {"
    text = text.replace(anchor, anchor + " " + call_marker, 1)

bootstrap.write_text(text)

package_path = Path("services/apim-bootstrapper/package.json")
package = json.loads(package_path.read_text())
start = package.setdefault("scripts", {}).get("start", "")
preflight_command = "node src/central-policy-preflight.js"
setup_command = "node src/central-policy-setup.js"

if preflight_command not in start:
    bootstrap_command = "node src/bootstrap.js"
    if bootstrap_command in start:
        start = start.replace(
            bootstrap_command,
            f"{preflight_command} && {bootstrap_command}",
            1,
        )
    else:
        start = f"{preflight_command} && {start}" if start else preflight_command

if setup_command not in start:
    anchors = [
        "node src/developer-experience-setup.js &&",
        "node src/api-product-bundles-setup.js &&",
    ]
    for anchor in anchors:
        if anchor in start:
            start = start.replace(anchor, f"{anchor} {setup_command} &&", 1)
            break
    else:
        start = f"{start} && {setup_command}" if start else setup_command

package["scripts"]["start"] = start
package_path.write_text(json.dumps(package, indent=2) + "\n")

bundles_path = Path("artifacts/apim-admin/api-product-bundles.json")
bundles = json.loads(bundles_path.read_text())
central_bundle = {
    "id": "central-policy-governance",
    "name": "Central Policy Governance Bundle",
    "description": "Group-wide and country-specific API governance decisions for Mexico and Brazil, exposed as a managed API and native API Product.",
    "businessStory": "A regional telco applies one mandatory group baseline while local owners route high-risk APIs through country-specific privacy, regulatory and security approval.",
    "businessOutcome": "Consistent production governance with explicit local accountability, residency, commercial metadata and auditable approval paths.",
    "buyer": "API platform, security, privacy, legal, product and country operating-company teams",
    "plan": "TelcoPartnerPremium",
    "plans": ["TelcoPartnerStandard", "TelcoPartnerPremium"],
    "markets": ["GROUP", "MX", "BR"],
    "apis": ["CentralPolicyDecisionAPI"],
    "apiBundle": [
        {
            "apiName": "CentralPolicyDecisionAPI",
            "capability": "Policy service health",
            "method": "GET",
            "path": "/health",
            "meter": "central_policy_read"
        },
        {
            "apiName": "CentralPolicyDecisionAPI",
            "capability": "Group and country policy evaluation",
            "method": "POST",
            "path": "/decisions",
            "meter": "central_policy_evaluation"
        }
    ],
    "apim": {
        "apiProductName": "CentralPolicyGovernanceProduct",
        "displayName": "Central Policy Governance",
        "context": "/products/central-policy-governance/v1",
        "version": "1.0.0",
        "visibility": "PUBLIC",
        "subscriptionPolicies": ["TelcoPartnerStandard", "TelcoPartnerPremium"],
        "apiThrottlingPolicy": "Unlimited",
        "governanceLabel": "Telco Governance APIs",
        "tags": ["governance", "opa", "mexico", "brazil", "regulatory"]
    },
    "moesif": {
        "companyId": "regional-telco-group",
        "productKey": "moesif_prod_central_policy_governance",
        "billingCatalogReference": "billing.catalog.central-policy-governance.v1",
        "revenueShareModel": "INTERNAL_GOVERNANCE_AND_PARTNER_TIER",
        "settlementOwner": "Group API Platform Governance",
        "productLine": "API Governance",
        "meters": ["api_call", "central_policy_read", "central_policy_evaluation"]
    }
}
by_id = {item.get("id"): item for item in bundles}
by_id[central_bundle["id"]] = central_bundle
ordered = [item for item in bundles if item.get("id") != central_bundle["id"]]
ordered.append(central_bundle)
bundles_path.write_text(json.dumps(ordered, indent=2) + "\n")

product_setup = Path("services/apim-bootstrapper/src/api-product-bundles-setup.js")
product_text = product_setup.read_text()
if "'central-policy-governance'" not in product_text:
    marker = "'5g-network-monetization'"
    if marker not in product_text:
        raise SystemExit("Could not locate native API Product bundle set.")
    product_text = product_text.replace(
        marker,
        marker + ", 'central-policy-governance'",
        1,
    )
product_setup.write_text(product_text)

developer = Path("services/apim-bootstrapper/src/developer-experience-setup.js")
developer_text = developer.read_text()
if "'CentralPolicyDecisionAPI'" not in developer_text:
    marker = "'NetworkEventsStreamAPI' ]);"
    if marker not in developer_text:
        raise SystemExit("Could not locate Developer Experience API set.")
    developer_text = developer_text.replace(
        marker,
        "'NetworkEventsStreamAPI', 'CentralPolicyDecisionAPI' ]);",
        1,
    )
if "'CentralPolicyGovernanceProduct'" not in developer_text:
    marker = "'SecureMobileTransactionsProduct' ]);"
    if marker not in developer_text:
        raise SystemExit("Could not locate Developer Experience product set.")
    developer_text = developer_text.replace(
        marker,
        "'SecureMobileTransactionsProduct', 'CentralPolicyGovernanceProduct' ]);",
        1,
    )
if "CentralPolicyDecisionAPI: [" not in developer_text:
    marker = "NetworkEventsStreamAPI: [ 'TelcoFreeTrial', 'TelcoEventStreamPremium' ]"
    if marker not in developer_text:
        raise SystemExit("Could not locate Developer Experience plan assignments.")
    developer_text = developer_text.replace(
        marker,
        marker + ", CentralPolicyDecisionAPI: [ 'TelcoPartnerStandard', 'TelcoPartnerPremium' ]",
        1,
    )
developer.write_text(developer_text)

control = Path("scripts/telco-demo-control.sh")
if control.exists():
    control_text = control.read_text()
    if "docker-compose.central-policy.yml" not in control_text:
        patterns = [
            ("docker-compose.opa.yml \\\n", "docker-compose.opa.yml \\\n  docker-compose.central-policy.yml \\\n"),
            ('"$ROOT_DIR/docker-compose.opa.yml"\n', '"$ROOT_DIR/docker-compose.opa.yml"\n  "$ROOT_DIR/docker-compose.central-policy.yml"\n'),
        ]
        replaced = False
        for old, new in patterns:
            if old in control_text:
                control_text = control_text.replace(old, new, 1)
                replaced = True
                break
        if not replaced:
            raise SystemExit("Could not add central-policy Compose overlay to telco-demo-control.sh.")
    if "telco-opa-dr" not in control_text:
        control_text = control_text.replace(
            "telco-opa telco-subscriber-crm",
            "telco-opa telco-opa-dr telco-subscriber-crm",
            1,
        )
    control.write_text(control_text)
PY

log "Writing Service Catalog registration."

cat > scripts/register-central-policy-service-catalog.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/central-policy-catalog.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in curl jq python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[central-policy-catalog] ERROR: missing command: $command" >&2
    exit 1
  }
done

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "central-policy-service-catalog-$(date +%s)-$$",
  "owner": "${APIM_USER}",
  "grantType": "password refresh_token client_credentials",
  "saasApp": true
}
JSON

DCR_RESPONSE="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d @"$WORK_DIR/dcr.json" \
    "${APIM_URL}/client-registration/v0.17/register"
)"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR_RESPONSE")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR_RESPONSE")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || {
  echo "[central-policy-catalog] ERROR: DCR failed." >&2
  jq . <<<"$DCR_RESPONSE" >&2 || true
  exit 1
}

TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=service_catalog:service_view service_catalog:service_write' \
    "${APIM_URL}/oauth2/token"
)"
ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"
[[ -n "$ACCESS_TOKEN" ]] || {
  echo "[central-policy-catalog] ERROR: token request failed." >&2
  jq . <<<"$TOKEN_RESPONSE" >&2 || true
  exit 1
}

cat > "$WORK_DIR/metadata.json" <<'JSON'
{
  "name": "CentralPolicyDecisionAPI",
  "version": "1.0.0",
  "description": "WSO2 Integrator: MI service that preserves correlation, wraps policy descriptors for OPA, normalizes decisions and uses bounded retry, failover and endpoint suspension.",
  "serviceUrl": "http://wso2-mi:8290/internal/central-policy/v1",
  "definitionType": "OAS3",
  "securityType": "NONE",
  "mutualSSLEnabled": false
}
JSON

python3 - "$WORK_DIR/openapi.json" <<'PY'
import json
import sys

definition = {
    "openapi": "3.0.3",
    "info": {
        "title": "Central Policy Decision API",
        "version": "1.0.0",
        "description": "MI-managed OPA decision facade with correlation, normalized errors and failover."
    },
    "servers": [
        {"url": "http://wso2-mi:8290/internal/central-policy/v1"}
    ],
    "paths": {
        "/health": {
            "get": {
                "operationId": "centralPolicyHealth",
                "responses": {
                    "200": {
                        "description": "Healthy",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "additionalProperties": True
                                }
                            }
                        }
                    }
                }
            }
        },
        "/decisions": {
            "post": {
                "operationId": "evaluateCentralPolicy",
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "additionalProperties": True
                            }
                        }
                    }
                },
                "responses": {
                    "200": {
                        "description": "Evaluated policy decision",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "additionalProperties": True
                                }
                            }
                        }
                    },
                    "503": {
                        "description": "Both bounded OPA endpoints unavailable"
                    }
                }
            }
        }
    }
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(definition, handle, indent=2)
    handle.write("\n")
PY

SEARCH_RESPONSE="$(
  curl -ksS -G \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    --data-urlencode 'name=CentralPolicyDecisionAPI' \
    --data-urlencode 'version=1.0.0' \
    --data-urlencode 'limit=100' \
    "${APIM_URL}/api/am/service-catalog/v1/services"
)"
EXISTING_ID="$(
  jq -r \
    'first(.list[]? | select(.name == "CentralPolicyDecisionAPI" and .version == "1.0.0") | .id) // empty' \
    <<<"$SEARCH_RESPONSE"
)"

RESPONSE_FILE="$WORK_DIR/response.json"
if [[ -n "$EXISTING_ID" ]]; then
  STATUS="$(
    curl -ksS -o "$RESPONSE_FILE" -w '%{http_code}' \
      -X PUT \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      -F "definitionFile=@$WORK_DIR/openapi.json;type=application/json" \
      -F "serviceMetadata=@$WORK_DIR/metadata.json;type=application/json" \
      "${APIM_URL}/api/am/service-catalog/v1/services/${EXISTING_ID}"
  )"
  ACTION=updated
else
  STATUS="$(
    curl -ksS -o "$RESPONSE_FILE" -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      -F "definitionFile=@$WORK_DIR/openapi.json;type=application/json" \
      -F "serviceMetadata=@$WORK_DIR/metadata.json;type=application/json" \
      "${APIM_URL}/api/am/service-catalog/v1/services"
  )"
  ACTION=created
fi

case "$STATUS" in
  200|201)
    echo "[central-policy-catalog] CentralPolicyDecisionAPI:1.0.0 ${ACTION}."
    ;;
  *)
    echo "[central-policy-catalog] ERROR: HTTP ${STATUS}" >&2
    cat "$RESPONSE_FILE" >&2
    exit 1
    ;;
esac

FINAL="$(
  curl -ksS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"
jq -e \
  'any(.list[]?; .name == "CentralPolicyDecisionAPI" and .version == "1.0.0")' \
  <<<"$FINAL" >/dev/null
echo "[central-policy-catalog] Verified CentralPolicyDecisionAPI in APIM Service Catalog."
BASH

chmod +x scripts/register-central-policy-service-catalog.sh

log "Writing comprehensive automated verification."

cat > scripts/verify-central-policy-overlays.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_GATEWAY_PUBLIC_URL:-https://127.0.0.1:8243}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
OPA_URL="${OPA_PUBLIC_URL:-http://127.0.0.1:8181}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
VERIFY_FAILOVER="${VERIFY_FAILOVER:-true}"

fail() {
  echo "[central-policy-verify] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[central-policy-verify] PASS: $*"
}

for command in curl jq python3 docker; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose was not found."
fi

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.central-policy.yml
do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

required_files=(
  artifacts/opa/central-policy-overlays.rego
  artifacts/apim-admin/central-policy-catalog.json
  contracts/openapi/central-policy-decision.openapi.yaml
  services/wso2-mi/synapse-configs/default/api/CentralPolicyDecisionAPI.xml
  services/wso2-mi/synapse-configs/default/endpoints/CentralPolicyOpaFailoverEndpoint.xml
  services/wso2-mi/synapse-configs/default/sequences/CentralPolicyFaultSequence.xml
  services/apim-bootstrapper/src/central-policy-preflight.js
  services/apim-bootstrapper/src/central-policy-setup.js
  scripts/register-central-policy-service-catalog.sh
  artifacts/postman/telco-central-policy-overlays.postman_collection.json
  docker-compose.central-policy.yml
)
for file in "${required_files[@]}"; do
  [[ -s "$file" ]] || fail "Missing or empty expected file: $file"
done
pass "All expected implementation files exist."

python3 -m json.tool artifacts/apim-admin/central-policy-catalog.json >/dev/null
python3 -m json.tool artifacts/apim-admin/api-product-bundles.json >/dev/null
python3 -m json.tool artifacts/postman/telco-central-policy-overlays.postman_collection.json >/dev/null
pass "JSON artifacts are valid."

grep -q "CENTRAL_POLICY_FAIL_ON_DENY: \"true\"" docker-compose.central-policy.yml ||
  fail "Selected production policies are not configured as blocking."
grep -q "OPA_FAIL_ON_DENY: \"false\"" docker-compose.central-policy.yml ||
  fail "The existing broad OPA overlay is no longer advisory."
grep -q "central-policy-preflight.js" services/apim-bootstrapper/package.json ||
  fail "Blocking central-policy preflight is absent from npm start."
grep -q "central-policy-setup.js" services/apim-bootstrapper/package.json ||
  fail "Central policy enrichment bootstrap is absent from npm start."
python3 - <<'PY'
import json
from pathlib import Path
package = json.loads(Path("services/apim-bootstrapper/package.json").read_text())
start = package.get("scripts", {}).get("start", "")
preflight = start.find("node src/central-policy-preflight.js")
bootstrap = start.find("node src/bootstrap.js")
if preflight < 0 or bootstrap < 0 or preflight > bootstrap:
    raise SystemExit(
        "Blocking central-policy preflight must execute before APIM publication."
    )
PY
grep -q "CentralPolicyDecisionAPI" services/apim-bootstrapper/src/bootstrap.js ||
  fail "Central policy API is absent from APICTL bootstrap."
grep -q "central-policy-governance" services/apim-bootstrapper/src/api-product-bundles-setup.js ||
  fail "Central policy bundle is not configured as a native API Product."
pass "Bootstrap and mixed blocking/advisory mode are installed."

"${COMPOSE[@]}" config -q
pass "Merged Docker Compose topology is valid."

wait_http() {
  local url="$1"
  local label="$2"
  local insecure="${3:-false}"
  local attempts="${4:-120}"
  local args=(-fsS --max-time 5)
  [[ "$insecure" == true ]] && args=(-kfsS --max-time 5)
  for _ in $(seq 1 "$attempts"); do
    if curl "${args[@]}" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "${label} did not become reachable: ${url}"
}

wait_http "${OPA_URL}/health" "OPA" false 30 || true
wait_http "${MI_URL}/internal/central-policy/v1/health" "MI central policy API" false 120
wait_http "${APIM_URL}/services/Version" "WSO2 API Manager" true 180
pass "OPA/MI/APIM runtime endpoints are reachable."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/central-policy-verify.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

descriptor() {
  local api_name="$1"
  jq -c --arg name "$api_name" \
    '.descriptors[] | select(.apiName == $name)' \
    artifacts/apim-admin/central-policy-catalog.json
}

opa_decision() {
  local payload="$1"
  curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson input "$payload" '{input:$input}')" \
    "${OPA_URL}/v1/data/telco/central_policy/decision"
}

MX="$(descriptor OpenGatewaySimSwapRiskAPI)"
BR="$(descriptor SecureMobileTransactionsCommercialAPI)"
GROUP="$(descriptor CentralPolicyDecisionAPI)"

MX_RESULT="$(opa_decision "$MX")"
jq -e '.result.allow == true and .result.country == "MX" and
       (.result.approvalPath.steps | index("Mexico Privacy and Legal")) != null' \
  <<<"$MX_RESULT" >/dev/null ||
  fail "Compliant Mexico descriptor was not allowed through the Mexico path."
pass "Compliant Mexico HIGH-risk descriptor uses the Mexico approval path."

BR_RESULT="$(opa_decision "$BR")"
jq -e '.result.allow == true and .result.country == "BR" and
       (.result.approvalPath.steps | index("Brazil Data Protection Officer")) != null' \
  <<<"$BR_RESULT" >/dev/null ||
  fail "Compliant Brazil descriptor was not allowed through the Brazil path."
pass "Compliant Brazil CRITICAL descriptor uses the Brazil DPO path."

GROUP_RESULT="$(opa_decision "$GROUP")"
jq -e '.result.allow == true and .result.country == "GROUP"' \
  <<<"$GROUP_RESULT" >/dev/null ||
  fail "Compliant group descriptor was not allowed."
pass "Mandatory group-wide descriptor is allowed."

MX_DENIED="$(jq 'del(.localOwner.email)' <<<"$MX")"
MX_DENIED_RESULT="$(opa_decision "$MX_DENIED")"
jq -e '.result.allow == false and
       any(.result.blocking[]; .code == "LOCAL_OWNER_EMAIL_REQUIRED")' \
  <<<"$MX_DENIED_RESULT" >/dev/null ||
  fail "Missing Mexico local owner email did not produce a blocking denial."
pass "Mandatory local-owner rule blocks production."

BR_DENIED="$(jq '.dataResidency = "MX"' <<<"$BR")"
BR_DENIED_RESULT="$(opa_decision "$BR_DENIED")"
jq -e '.result.allow == false and
       any(.result.blocking[]; .code == "DATA_RESIDENCY_MISMATCH")' \
  <<<"$BR_DENIED_RESULT" >/dev/null ||
  fail "Brazil residency mismatch did not produce a blocking denial."
pass "Brazil data-residency mismatch blocks production."

ADVISORY_INPUT="$(jq '.evidence.sdkInstructions = false' <<<"$MX")"
ADVISORY_RESULT="$(opa_decision "$ADVISORY_INPUT")"
jq -e '.result.allow == true and .result.partialResponse == true and
       any(.result.advisories[]; .code == "SDK_INSTRUCTIONS_RECOMMENDED")' \
  <<<"$ADVISORY_RESULT" >/dev/null ||
  fail "Advisory documentation rule incorrectly blocked the decision."
pass "Advisory findings remain non-blocking and produce a partial response."

CORRELATION="central-policy-mi-$(date +%s)"
MI_HEADERS="$WORK_DIR/mi.headers"
MI_BODY="$WORK_DIR/mi.json"
curl -fsS \
  -D "$MI_HEADERS" \
  -o "$MI_BODY" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${CORRELATION}" \
  -d "$MX" \
  "${MI_URL}/internal/central-policy/v1/decisions"
jq -e --arg c "$CORRELATION" \
  '.allow == true and .correlationId == $c and .country == "MX"' \
  "$MI_BODY" >/dev/null ||
  fail "MI did not return the allowed Mexico decision with correlation."
grep -Eiq "^X-Correlation-ID: ${CORRELATION}\r?$" "$MI_HEADERS" ||
  fail "MI did not preserve X-Correlation-ID in the transport response."
pass "MI mediation preserves correlation and normalizes the OPA envelope."

if [[ "$VERIFY_FAILOVER" == true ]]; then
  echo "[central-policy-verify] Exercising OPA primary-to-DR failover."
  "${COMPOSE[@]}" stop opa >/dev/null
  trap '"${COMPOSE[@]}" start opa >/dev/null 2>&1 || true; rm -rf "$WORK_DIR"' EXIT
  sleep 2
  FAILOVER_RESULT="$(
    curl -fsS \
      -H 'Content-Type: application/json' \
      -H 'X-Correlation-ID: central-policy-failover-001' \
      -d "$BR" \
      "${MI_URL}/internal/central-policy/v1/decisions"
  )"
  jq -e '.allow == true and .country == "BR"' <<<"$FAILOVER_RESULT" >/dev/null ||
    fail "MI did not fail over to opa-dr."
  "${COMPOSE[@]}" start opa >/dev/null
  wait_http "${OPA_URL}/health" "restarted OPA" false 30 || true
  trap 'rm -rf "$WORK_DIR"' EXIT
  pass "MI failed over from primary OPA to opa-dr."
fi

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "central-policy-verifier-$(date +%s)-$$",
  "owner": "${APIM_USER}",
  "grantType": "password refresh_token client_credentials",
  "saasApp": true
}
JSON

DCR="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d @"$WORK_DIR/dcr.json" \
    "${APIM_URL}/client-registration/v0.17/register"
)"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] ||
  fail "APIM DCR did not return credentials."

TOKEN="$(
  curl -ksS \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish apim:api_metadata_view service_catalog:service_view apim:app_manage apim:sub_manage apim:subscribe apim:api_key apim:api_generate_key' \
    "${APIM_URL}/oauth2/token"
)"
ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN")"
[[ -n "$ADMIN_TOKEN" ]] || fail "APIM admin token was not returned."

APIS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

for name in \
  CentralPolicyDecisionAPI \
  OpenGatewaySimSwapRiskAPI \
  SecureMobileTransactionsCommercialAPI
do
  id="$(
    jq -r --arg name "$name" \
      'first(.list[]? | select(.name == $name and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
      <<<"$APIS"
  )"
  [[ -n "$id" ]] || fail "Expected Publisher API is absent: ${name}:1.0.0"
  detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}"
  )"
  jq -e '.lifeCycleStatus == "PUBLISHED"' <<<"$detail" >/dev/null ||
    fail "${name} is not PUBLISHED."
  jq -e \
    'any(.additionalProperties[]?; .name == "CentralPolicyEnforcement" and .value == "BLOCKING_PRODUCTION_AND_ADVISORY_REPORT_ONLY")' \
    <<<"$detail" >/dev/null ||
    fail "${name} lacks central-policy metadata."

  case "$name" in
    CentralPolicyDecisionAPI) expected_policy="TelcoPartnerPremium" ;;
    OpenGatewaySimSwapRiskAPI) expected_policy="TelcoOpenGatewayTrustPremium" ;;
    SecureMobileTransactionsCommercialAPI) expected_policy="SecureMobileEnterprise" ;;
    *) fail "No expected policy mapping for ${name}." ;;
  esac
  jq -e --arg policy "$expected_policy" \
    '(.policies // []) | index($policy) != null' \
    <<<"$detail" >/dev/null ||
    fail "${name} is missing subscription policy ${expected_policy}."

  documents="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}/documents?limit=100"
  )"
  for document in \
    "10 - Central Policy and Country Overlay" \
    "11 - Consent Privacy and Data Residency" \
    "12 - Errors SLA Sandbox Postman and SDK"
  do
    jq -e --arg document "$document" \
      'any(.list[]?; .name == $document)' \
      <<<"$documents" >/dev/null ||
      fail "${name} is missing document: ${document}"
  done

  deployments="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}/deployments"
  )"
  jq -e '
    if type == "array" then
      length > 0
    elif type == "object" then
      ((.list // .data // .deployments // []) | length) > 0
    else
      false
    end
  ' <<<"$deployments" >/dev/null ||
    fail "${name} has no deployed revision."
done
pass "Expected APIs are published, deployed, documented and centrally labelled."

PRODUCTS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000"
)"
PRODUCT_ID="$(
  jq -r \
    'first(.list[]? | select(.name == "CentralPolicyGovernanceProduct" and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
    <<<"$PRODUCTS"
)"
[[ -n "$PRODUCT_ID" ]] ||
  fail "CentralPolicyGovernanceProduct:1.0.0 is absent."

PRODUCT="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}"
)"
jq -e '
  ((.state // .lifeCycleStatus // .status) | ascii_upcase) == "PUBLISHED" and
  any(.apis[]?; .name == "CentralPolicyDecisionAPI") and
  ((.policies // []) | index("TelcoPartnerPremium") != null)
' <<<"$PRODUCT" >/dev/null ||
  fail "CentralPolicyGovernanceProduct is not PUBLISHED, lacks its member API or lacks TelcoPartnerPremium."

PRODUCT_DEPLOYMENTS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/deployments"
)"
jq -e '
  if type == "array" then
    length > 0
  elif type == "object" then
    ((.list // .data // .deployments // []) | length) > 0
  else
    false
  end
' <<<"$PRODUCT_DEPLOYMENTS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct has no deployed revision."

PRODUCT_DOCS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/documents?limit=100"
)"
jq -e '(.list | length) >= 3' <<<"$PRODUCT_DOCS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct lacks expected documentation."
pass "Native API Product is published, contains the managed API and has documentation."

DEVPORTAL_APIS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
)"
for name in \
  CentralPolicyDecisionAPI \
  OpenGatewaySimSwapRiskAPI \
  SecureMobileTransactionsCommercialAPI
do
  jq -e --arg name "$name" \
    'any((.list // .)[]?; .name == $name and ((.status // "PUBLISHED") | ascii_upcase) == "PUBLISHED")' \
    <<<"$DEVPORTAL_APIS" >/dev/null ||
    fail "${name} is not visible in the Developer Portal API listing."
done

DEVPORTAL_PRODUCT_FILE="$WORK_DIR/devportal-products.json"
DEVPORTAL_PRODUCT_STATUS="$(
  curl -ksS \
    -o "$DEVPORTAL_PRODUCT_FILE" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/devportal/v3/api-products?limit=1000"
)"
if [[ "$DEVPORTAL_PRODUCT_STATUS" == 200 ]]; then
  DEVPORTAL_PRODUCTS="$(cat "$DEVPORTAL_PRODUCT_FILE")"
else
  # Some 4.x distributions expose products in the unified /apis marketplace
  # result instead of a separate collection resource.
  DEVPORTAL_PRODUCTS="$DEVPORTAL_APIS"
fi
jq -e \
  'any((.list // .)[]?; .name == "CentralPolicyGovernanceProduct" and
       ((.status // "PUBLISHED") | ascii_upcase) == "PUBLISHED")' \
  <<<"$DEVPORTAL_PRODUCTS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct is not visible in the Developer Portal."
pass "Governed APIs and the native API Product are visible in the Developer Portal."

CATALOG="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"
jq -e \
  'any(.list[]?; .name == "CentralPolicyDecisionAPI" and .version == "1.0.0")' \
  <<<"$CATALOG" >/dev/null ||
  fail "CentralPolicyDecisionAPI is absent from APIM Service Catalog."
pass "MI-managed service is registered in APIM Service Catalog."

UNAUTH_STATUS="$(
  curl -ksS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$GROUP" \
    "${GATEWAY_URL}/central-policy-decision/v1/1.0.0/decisions"
)"
case "$UNAUTH_STATUS" in
  401|403) ;;
  *) fail "Gateway did not enforce OAuth; expected 401/403, got ${UNAUTH_STATUS}." ;;
esac
pass "APIM gateway deployment enforces OAuth."

RUNTIME_STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/runtime.json 2>/dev/null
)" || fail "Could not read APIM bootstrap runtime state."

CONSUMER_KEY="$(jq -r '.application.consumerKey // empty' <<<"$RUNTIME_STATE")"
CONSUMER_SECRET="$(jq -r '.application.consumerSecret // empty' <<<"$RUNTIME_STATE")"
[[ -n "$CONSUMER_KEY" && -n "$CONSUMER_SECRET" ]] ||
  fail "Regional Portal production credentials are absent from runtime state."

APP_TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode 'scope=central-policy:evaluate central-policy:read' \
    "${APIM_URL}/oauth2/token"
)"
APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_RESPONSE")"
if [[ -z "$APP_TOKEN" ]]; then
  APP_TOKEN_RESPONSE="$(
    curl -ksS \
      -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
      --data-urlencode 'grant_type=client_credentials' \
      "${APIM_URL}/oauth2/token"
  )"
  APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_RESPONSE")"
fi
[[ -n "$APP_TOKEN" ]] || fail "Could not obtain a Regional Portal application token."

GATEWAY_CORRELATION="central-policy-gateway-$(date +%s)"
GATEWAY_HEADERS="$WORK_DIR/gateway.headers"
GATEWAY_BODY="$WORK_DIR/gateway.json"
curl -ksS \
  -D "$GATEWAY_HEADERS" \
  -o "$GATEWAY_BODY" \
  -H "Authorization: Bearer ${APP_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${GATEWAY_CORRELATION}" \
  -d "$MX" \
  "${GATEWAY_URL}/central-policy-decision/v1/1.0.0/decisions"
jq -e --arg c "$GATEWAY_CORRELATION" \
  '.allow == true and .country == "MX" and .correlationId == $c' \
  "$GATEWAY_BODY" >/dev/null ||
  fail "Authenticated APIM gateway call did not return the expected decision."
pass "Authenticated APIM → MI → OPA runtime behavior succeeded."

MI_LOGS="$("${COMPOSE[@]}" logs --no-color wso2-mi 2>&1)"
grep -q "central-policy-evaluation-start" <<<"$MI_LOGS" ||
  fail "MI observability logs lack central-policy-evaluation-start."
grep -q "central-policy-evaluation-complete" <<<"$MI_LOGS" ||
  fail "MI observability logs lack central-policy-evaluation-complete."
grep -q "${GATEWAY_CORRELATION}" <<<"$MI_LOGS" ||
  fail "MI observability logs do not contain the gateway correlation identifier."
pass "Central-policy decision and correlation are visible in the existing MI log pipeline."

PREFLIGHT_STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/central-policy-preflight.json 2>/dev/null
)" || fail "Could not read central-policy preflight state."
jq -e '
  .status == "READY" and
  .failOnDeny == true and
  (.decisions | length) == 3 and
  all(.decisions[]; .allow == true and .blockingCount == 0)
' <<<"$PREFLIGHT_STATE" >/dev/null ||
  fail "Blocking central-policy preflight state is incomplete or denied."
pass "Blocking preflight completed before APIM publication."

STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/central-policy.json 2>/dev/null
)" || fail "Could not read central-policy bootstrap state."
jq -e '
  .status == "READY" and
  (.apis | length) == 3 and
  (.products | length) == 1 and
  .serviceCatalog.name == "CentralPolicyDecisionAPI" and
  all(.decisions[]; .allow == true)
' <<<"$STATE" >/dev/null ||
  fail "Central-policy bootstrap state is incomplete or denied."
pass "Central-policy bootstrap state is complete."

echo
echo "[central-policy-verify] SUCCESS"
echo "[central-policy-verify] 3 governed APIs"
echo "[central-policy-verify] 1 published native API Product"
echo "[central-policy-verify] 3 APIM documents per governed API"
echo "[central-policy-verify] 1 MI Service Catalog entry"
echo "[central-policy-verify] blocking GROUP/MX/BR production gates"
echo "[central-policy-verify] non-blocking advisory partial responses"
echo "[central-policy-verify] correlation, observability, OAuth, Developer Portal visibility, deployment and OPA failover verified"
BASH

chmod +x scripts/verify-central-policy-overlays.sh

log "Writing a deterministic compose helper for the complete topology."

cat > scripts/central-policy-compose.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "[central-policy-compose] Docker Compose was not found." >&2
  exit 1
fi

files=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.central-policy.yml
do
  [[ -f "$file" ]] && files+=("$file")
done

command=("${DC[@]}")
for file in "${files[@]}"; do
  command+=(-f "$file")
done

exec "${command[@]}" "$@"
BASH

chmod +x scripts/central-policy-compose.sh

log "Validating generated and patched artifacts."

python3 -m json.tool artifacts/apim-admin/central-policy-catalog.json >/dev/null
python3 -m json.tool artifacts/apim-admin/api-product-bundles.json >/dev/null
python3 -m json.tool artifacts/postman/telco-central-policy-overlays.postman_collection.json >/dev/null
python3 -m json.tool services/apim-bootstrapper/package.json >/dev/null

if command -v node >/dev/null 2>&1; then
  node --check services/apim-bootstrapper/src/bootstrap.js
  node --check services/apim-bootstrapper/src/central-policy-preflight.js
  node --check services/apim-bootstrapper/src/central-policy-setup.js
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout \
    services/wso2-mi/synapse-configs/default/api/CentralPolicyDecisionAPI.xml \
    services/wso2-mi/synapse-configs/default/endpoints/CentralPolicyOpaFailoverEndpoint.xml \
    services/wso2-mi/synapse-configs/default/sequences/CentralPolicyFaultSequence.xml
fi

if command -v opa >/dev/null 2>&1; then
  opa check artifacts/opa/central-policy-overlays.rego
fi

if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
  ./scripts/central-policy-compose.sh config -q
fi

cat <<'OUT'

[central-policy-install] Installation complete.

Build and start the complete repository topology:
  ./scripts/telco-demo-control.sh restart

The existing controller runs its six-service MI registration; the central-policy
bootstrap now adds CentralPolicyDecisionAPI idempotently during the same run.

Verify:
  ./scripts/verify-central-policy-overlays.sh

Use VERIFY_FAILOVER=false only when intentionally skipping the destructive
primary-OPA stop/start portion:
  VERIFY_FAILOVER=false ./scripts/verify-central-policy-overlays.sh
OUT

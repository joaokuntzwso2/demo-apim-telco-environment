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

package telco.apim.governance

import rego.v1

default allow := false

allow if {
  count(deny) == 0
}

decision := {
  "allow": allow,
  "deny": deny,
  "warn": warn,
  "validationCount": 3,
  "story": "OPA validates APIM productization, Open Gateway commercial safety, and regional/federated gateway readiness for a large telco operating model."
}

is_empty(x) if {
  x == null
}

is_empty(x) if {
  x == ""
}

is_empty(x) if {
  x == []
}

bundle := input.bundle if {
  input.kind == "api_product_bundle"
}

dashboard := input.dashboard if {
  input.kind == "regional_gateway_dashboard"
}

plans_contains(plan) if {
  object.get(bundle, "plans", [])[_] == plan
}

high_risk_bundle if {
  name := lower(object.get(bundle, "name", ""))
  contains(name, "fraud")
}

high_risk_bundle if {
  name := lower(object.get(bundle, "name", ""))
  contains(name, "open gateway")
}

high_risk_bundle if {
  api := object.get(bundle, "apis", [])[_]
  contains(lower(api), "sim")
}

high_risk_bundle if {
  api := object.get(bundle, "apis", [])[_]
  contains(lower(api), "location")
}

deny contains msg if {
  input.kind == "api_product_bundle"
  apim := object.get(bundle, "apim", {})
  is_empty(object.get(apim, "apiProductName", ""))
  msg := sprintf("APIM API Product name is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  apim := object.get(bundle, "apim", {})
  is_empty(object.get(apim, "context", ""))
  msg := sprintf("APIM context is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  moesif := object.get(bundle, "moesif", {})
  is_empty(object.get(moesif, "billingCatalogReference", ""))
  msg := sprintf("Moesif billing catalog reference is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  moesif := object.get(bundle, "moesif", {})
  is_empty(object.get(moesif, "settlementOwner", ""))
  msg := sprintf("Settlement owner is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  is_empty(object.get(bundle, "plans", []))
  msg := sprintf("At least one commercial plan is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  is_empty(object.get(bundle, "markets", []))
  msg := sprintf("At least one target market is required for bundle '%s'.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  high_risk_bundle
  not plans_contains("TelcoOpenGatewayTrustPremium")
  msg := sprintf("High-risk Open Gateway bundle '%s' must include TelcoOpenGatewayTrustPremium.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "api_product_bundle"
  high_risk_bundle
  moesif := object.get(bundle, "moesif", {})
  is_empty(object.get(moesif, "meters", []))
  msg := sprintf("High-risk Open Gateway bundle '%s' must include billable Moesif meters.", [object.get(bundle, "name", "unknown")])
}

deny contains msg if {
  input.kind == "regional_gateway_dashboard"
  runtime := object.get(dashboard, "federatedRuntimes", [])[_]
  runtime.status != "Healthy"
  not has_healthy_failover(runtime.id)
  msg := sprintf("Runtime '%s' is not healthy and no healthy federated failover target is available.", [runtime.id])
}

has_healthy_failover(runtime_id) if {
  other := object.get(dashboard, "federatedRuntimes", [])[_]
  other.id != runtime_id
  other.status == "Healthy"
}

warn contains msg if {
  input.kind == "regional_gateway_dashboard"
  runtime := object.get(dashboard, "federatedRuntimes", [])[_]
  runtime.status == "Warning"
  msg := sprintf("Runtime '%s' is in Warning state; regional failover simulation should be shown in the demo.", [runtime.id])
}

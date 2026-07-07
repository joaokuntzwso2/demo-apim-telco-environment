# Telco Developer Portal Enablement

This implementation makes Developer Portal onboarding part of the automated APIM bootstrap.

## Generated for every demo API

1. Business overview
2. Contract and CAMARA alignment
3. Authentication and first-call guide
4. Consent and privacy requirements
5. Error catalogue
6. Rate limits and commercial plans
7. SLA, support and resilience
8. Code samples, Postman and generated SDK guidance
9. Sandbox test data

## Generated for every native API Product

1. Product overview and API map
2. Product onboarding and first call
3. Consent and compliance matrix
4. Commercial plans, rate limits and SLA
5. Sandbox, Postman and SDK toolkit

## Runtime behavior

- The bootstrap enriches API and API Product metadata through Publisher REST API v4.
- It assigns Bronze, Silver, Gold and Unlimited subscription policies.
- It creates or updates Markdown documentation idempotently.
- It deploys and publishes native API Products for Developer Portal visibility.
- APIM is configured to allow API document visibility and multiple generated SDK languages.
- The existing MI Service Catalog scripts remain authoritative for MI service registration.
- Existing MI endpoint failover, timeout and suspension settings are validated as the circuit-breaking implementation.

## Validation

Run:

```bash
./scripts/verify-mi-resilience-config.sh
./scripts/run-with-mi-risk.sh
./scripts/verify-developer-experience.sh
```

`run-with-mi-risk.sh` starts the complete APIM + MI topology, registers both MI
Service Catalog groups, and runs the APIM bootstrapper. The two registration
scripts remain independently rerunnable for troubleshooting.

# Consent and sandbox data

Consumers must provide a `consentId` that can be mapped to their consent or other lawful-basis record. Do not send secrets or raw identity documents in this field. Production onboarding should define retention, revocation and subject-right handling with the operator.

Sandbox responses mask MSISDN data while preserving deterministic response structure, correlation and usage metadata. `forceOutcome` and `/demo/*` are demonstration controls and must not be exposed in a production contract.

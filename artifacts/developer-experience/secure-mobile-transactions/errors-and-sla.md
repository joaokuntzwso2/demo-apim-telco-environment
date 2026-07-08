# Errors, retries and SLA

Functional rejections return HTTP 422 with a normalized business outcome and a zero-valued usage event. Transport failures return `application/problem+json` with HTTP 503 and the same `X-Correlation-ID` used in MI logs.

The MI endpoint uses a three-second timeout, two bounded retries, exponential endpoint suspension and failover from the primary to the secondary persistence adapter. QoD may return `PARTIAL` when activation succeeds but live telemetry is unavailable; the response contains warnings and uses a 0.70 billing factor.

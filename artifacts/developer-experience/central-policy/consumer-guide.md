# Central Policy Consumer Guide

The Central Policy Decision API exposes the same group-wide OPA decision through
WSO2 API Manager while WSO2 Integrator: MI performs correlation, request
wrapping, normalized response handling, timeouts, bounded retries, failover and
endpoint suspension.

A policy denial is returned as HTTP 200 with `allow=false`; it is not a transport
failure. Production descriptors are blocked when mandatory group, country,
risk, residency, ownership, regulatory, approval or commercial metadata is
absent. Documentation maturity remains advisory.

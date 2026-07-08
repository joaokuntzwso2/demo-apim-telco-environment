#!/usr/bin/env bash
set -euo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-telco-wso2-demo-kit}"
compose=(
  docker compose
  -p "${PROJECT}"
  -f docker-compose.yml
  -f docker-compose.kafka.yml
  -f docker-compose.opa.yml
  -f docker-compose.mi.yml
  -f docker-compose.oauth-business-controls.yml
  -f docker-compose.commercial.yml
  -f docker-compose.mi.soap.yml
  -f docker-compose.observability.yml
  -f docker-compose.runtime-persistence.yml
)

"${compose[@]}" build
"${compose[@]}" up -d --remove-orphans
"${compose[@]}" run --rm apim-bootstrapper
bash scripts/register-mi-service-catalog.sh
bash scripts/register-oauth-business-control-service-catalog.sh
bash scripts/verify-oauth-consent-risk-controls.sh

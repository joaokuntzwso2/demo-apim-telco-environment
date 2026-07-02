FROM node:20-bookworm-slim

WORKDIR /app

ARG APICTL_VERSION=4.7.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash curl ca-certificates tar gzip findutils dpkg \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  ARCH="$(dpkg --print-architecture)"; \
  case "$ARCH" in \
    amd64) APICTL_ARCH="linux-amd64" ;; \
    arm64) APICTL_ARCH="linux-arm64" ;; \
    *) echo "Unsupported architecture for apictl: $ARCH" >&2; exit 1 ;; \
  esac; \
  echo "Installing apictl ${APICTL_VERSION} for ${APICTL_ARCH}"; \
  curl -fL -o /tmp/apictl.tar.gz "https://github.com/wso2/product-apim-tooling/releases/download/v${APICTL_VERSION}/apictl-${APICTL_VERSION}-${APICTL_ARCH}.tar.gz"; \
  mkdir -p /tmp/apictl-download; \
  tar -xzf /tmp/apictl.tar.gz -C /tmp/apictl-download; \
  APICLI_PATH="$(find /tmp/apictl-download -type f -name apictl | head -1)"; \
  test -n "$APICLI_PATH"; \
  install -m 755 "$APICLI_PATH" /usr/local/bin/apictl; \
  apictl version; \
  rm -rf /tmp/apictl*

COPY services/apim-bootstrapper/package*.json ./
RUN npm install --omit=dev

COPY services/apim-bootstrapper/src ./src
COPY artifacts /workspace/artifacts
COPY contracts /workspace/contracts

RUN mkdir -p /workspace/state /workspace/generated

CMD ["npm", "start"]

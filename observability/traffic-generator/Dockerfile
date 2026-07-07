FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    jq \
    openssl

WORKDIR /app

COPY run.sh /app/run.sh

RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]

# BEGIN TELCO AI MODULE BUILD
FROM alpine:3.21 AS telco-ai-module

ARG MI_AI_VERSION=0.2.2
ARG MI_AI_SHA256=f05474bfa6f27865f67b1541b0433361304046b418d4012fb99b09b063d1ab9b

RUN apk add --no-cache ca-certificates curl \
    && mkdir -p /out \
    && curl --fail --location \
         --retry 5 \
         --retry-delay 3 \
         --connect-timeout 30 \
         --output /out/mi-connector-ai.zip \
         "https://github.com/wso2-extensions/mi-module-generative-ai/releases/download/v${MI_AI_VERSION}/ai-connector-${MI_AI_VERSION}.zip" \
    && echo "${MI_AI_SHA256}  /out/mi-connector-ai.zip" | sha256sum -c -
FROM wso2/wso2mi:4.6.0-alpine
USER root

COPY synapse-configs/default/ ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs/default/
COPY --from=telco-ai-module /out/mi-connector-ai.zip ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-libs/mi-connector-ai.zip
COPY conf/file.properties ${WSO2_SERVER_HOME}/conf/file.properties
COPY conf/service-catalog.toml /tmp/service-catalog.toml
COPY wait-for-apim.sh /home/wso2carbon/wait-for-apim.sh
COPY ai-entrypoint.sh /home/wso2carbon/ai-entrypoint.sh

RUN cat /tmp/service-catalog.toml >> ${WSO2_SERVER_HOME}/conf/deployment.toml \
    && rm -f /tmp/service-catalog.toml \
    && chmod 0755 /home/wso2carbon/wait-for-apim.sh \
    && chmod -R a+rX ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs/default \
    && chmod a+r ${WSO2_SERVER_HOME}/conf/deployment.toml ${WSO2_SERVER_HOME}/conf/file.properties

USER 10802

EXPOSE 8290 8253 9164

ENTRYPOINT ["/home/wso2carbon/ai-entrypoint.sh"]

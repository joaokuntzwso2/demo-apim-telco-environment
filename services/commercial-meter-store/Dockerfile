FROM node:20-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
RUN mkdir -p /data && chown -R node:node /app /data
USER node
ENV PORT=8086 STATE_FILE=/data/commercial-meter-state.json
EXPOSE 8086
HEALTHCHECK --interval=10s --timeout=3s --retries=20 --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8086/health >/dev/null || exit 1
CMD ["node", "src/server.js"]

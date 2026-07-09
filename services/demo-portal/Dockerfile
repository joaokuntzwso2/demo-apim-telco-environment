FROM node:20-bookworm-slim

WORKDIR /app

COPY services/demo-portal/package*.json ./
RUN npm install --omit=dev

COPY services/demo-portal/server.js ./server.js
COPY services/demo-portal/telco-ai-routes.js ./telco-ai-routes.js
COPY services/demo-portal/public ./public

EXPOSE 8080

CMD ["npm", "start"]

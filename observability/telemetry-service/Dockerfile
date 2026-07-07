FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY src ./src
RUN mkdir -p /data && chown -R node:node /app /data
USER node
CMD ["npm","start"]

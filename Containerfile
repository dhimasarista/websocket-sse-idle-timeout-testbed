FROM docker.io/library/node:22-alpine

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server ./server
COPY client ./client

ENV NODE_ENV=production
CMD ["node", "server/index.js"]

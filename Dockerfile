FROM node:18-alpine

WORKDIR /app

# Install production dependencies first (separate layer for better caching)
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# Copy application source (images, HTML, server code, DB schema)
COPY . .

# Cloud Run injects PORT=8080; the app already reads process.env.PORT
EXPOSE 8080

# Drop root privileges at runtime
USER node

CMD ["node", "server.js"]

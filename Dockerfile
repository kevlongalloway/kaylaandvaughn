FROM node:20-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm ci --only=production

# Copy app source
COPY . .

# Cloud Run sets PORT=8080 automatically
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]

# TapKar AI backend — Cloud Run container.
# Build context: repo root (so we can copy both backend/ and data/).
FROM node:20-alpine

# Wget for healthcheck
RUN apk add --no-cache wget

WORKDIR /app

# Install deps (use ci for deterministic builds; keep tsx + types so tsx can run TS)
COPY backend/package*.json ./backend/
RUN cd backend && npm ci --no-audit --no-fund

# Copy source + data (data lives at repo root, agents need it at runtime)
COPY backend/src ./backend/src
COPY backend/tsconfig.json ./backend/
COPY data ./data

WORKDIR /app/backend

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget --spider -q http://localhost:8080/healthz || exit 1

# Use tsx in production — same module resolution as dev, no separate compile step
CMD ["npx", "tsx", "src/index.ts"]

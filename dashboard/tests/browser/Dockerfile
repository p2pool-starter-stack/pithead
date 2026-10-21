FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

WORKDIR /probe
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts \
    && ./node_modules/.bin/playwright install --with-deps chromium \
    && apt-get update \
    && apt-get install -y --no-install-recommends libnss3-tools \
    && rm -rf /var/lib/apt/lists/*
COPY dashboard-ca-probe.mjs ./
ENTRYPOINT ["node", "/probe/dashboard-ca-probe.mjs"]

FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

WORKDIR /probe
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts \
    && ./node_modules/.bin/playwright install --with-deps chromium \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends libnss3-tools \
    && rm -rf /var/lib/apt/lists/* /usr/local/lib/node_modules /opt/yarn* \
        /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
        /usr/local/bin/yarn /usr/local/bin/yarnpkg
COPY dashboard-ca-probe.mjs ./
ENTRYPOINT ["node", "/probe/dashboard-ca-probe.mjs"]

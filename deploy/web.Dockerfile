# Builds and runs the Next.js web client (docs/deploy.md §12).
#
# The build context is the app directory (web/), not the repo root. On a server
# deployment the file is copied next to the sources as `Dockerfile`:
#
#   /opt/courseplanner-web/  <- web/ sources + Dockerfile + docker-compose.yml
#
# API_PROXY_TARGET is baked into the routes manifest at build time (the /api and
# /healthz rewrites live there), so it is a build arg, not only a runtime env
# var: point it at the backend reachable from *this* container.
FROM node:22-alpine AS build
ARG API_PROXY_TARGET=http://127.0.0.1:8080
ARG NPM_REGISTRY=https://registry.npmmirror.com
ENV API_PROXY_TARGET=$API_PROXY_TARGET \
    NEXT_TELEMETRY_DISABLED=1
WORKDIR /app
COPY package.json package-lock.json ./
# The default registry is not reachable from every host; override with
# --build-arg NPM_REGISTRY=https://registry.npmjs.org when it is.
RUN npm config set registry "$NPM_REGISTRY" && npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine AS run
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1
WORKDIR /app
COPY --from=build /app/package.json /app/next.config.ts ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
RUN addgroup -S app && adduser -S -G app app && chown -R app:app /app
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/login >/dev/null 2>&1 || exit 1
CMD ["node_modules/.bin/next", "start", "-H", "0.0.0.0", "-p", "3000"]

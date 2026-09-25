# GeoGuard server image, built from the repository root.
#
# Render's default Docker settings build from the repo root with ./Dockerfile,
# so this file makes those defaults work with no extra configuration. It is
# the same image as server/Dockerfile (used when Root Directory is `server`).
# Only the server is copied in; the Flutter app never enters the image.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

# Dependencies first, so a code-only change reuses this cached layer.
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY server/src ./src

# The official image ships an unprivileged `node` user; run as it.
USER node

EXPOSE 8080
CMD ["node", "src/index.js"]

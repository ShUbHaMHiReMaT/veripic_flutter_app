# GeoGuard server image.
#
# Used on Render with Language: Docker and Root Directory: server. Render
# builds this image itself and passes PORT and every environment variable set
# in the dashboard at run time — no secret is baked into the image.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

# Dependencies first, so a code-only change reuses this cached layer.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY src ./src

# The official image ships an unprivileged `node` user; run as it.
USER node

EXPOSE 8080
CMD ["node", "src/index.js"]

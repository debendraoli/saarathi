# NEXT_PUBLIC_* vars are baked in at build time, not read at container
# runtime — pass the real gateway URL as a build arg (CI does this with the
# actual domain; local `docker build` without it falls back to localhost).
ARG NEXT_PUBLIC_API_BASE=http://localhost:8080

FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:20-alpine AS build
WORKDIR /app
ARG NEXT_PUBLIC_API_BASE
ENV NEXT_PUBLIC_API_BASE=${NEXT_PUBLIC_API_BASE}
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# No public/ dir in this project today — create an empty one so the runtime
# stage's COPY below doesn't depend on that never changing.
RUN mkdir -p public && npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]

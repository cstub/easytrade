FROM node:24.11.0-alpine3.22@sha256:f36fed0b2129a8492535e2853c64fbdbd2d29dc1219ee3217023ca48aebd3787 AS build

WORKDIR /app

COPY ["*.json", "./"]
COPY ["./src", "./src"]

RUN npm ci \
    && npm run build

FROM node:24.11.0-alpine3.22@sha256:f36fed0b2129a8492535e2853c64fbdbd2d29dc1219ee3217023ca48aebd3787 AS dev

RUN apk upgrade --no-cache \
    && addgroup --system --gid 3369 easytrade \
    && adduser --system --ingroup easytrade --uid 3369 easytrade
USER easytrade:easytrade
WORKDIR /home/easytrade

COPY --chown=easytrade:easytrade ["package.json", "package-lock.json", "./"]

RUN npm ci --omit=dev \
    && npm cache clean --force

COPY --chown=easytrade:easytrade --from=build ["app/dist", "./dist"]

# OpenTelemetry Node.js auto-instrumentation must load before the application modules.
# OTEL_* environment variables configure it; the Winston logs reach it through
# @opentelemetry/winston-transport, so no transport is added to the logger by hand.
# Only local resource detectors: the cloud ones probe metadata endpoints at startup.
ENV OTEL_NODE_RESOURCE_DETECTORS=env,host,os,process,container

CMD [ "node", "--require", "@opentelemetry/auto-instrumentations-node/register", "./dist/src/app.js" ]

# https://mcr.microsoft.com/v2/dotnet/sdk/tags/list
FROM mcr.microsoft.com/dotnet/sdk:8.0.412-alpine3.22@sha256:ad6ab1a677854e5b681bc69f4fdb4ad9913e3798c4f89927254b6a53215d5b7d AS build

WORKDIR /BrokerService
COPY ["BrokerService/", "./"]

RUN dotnet test test/BrokerService.test.csproj \
    && dotnet publish src/BrokerService.csproj -o /publish

# https://mcr.microsoft.com/v2/dotnet/aspnet/tags/list
FROM mcr.microsoft.com/dotnet/aspnet:8.0.18-alpine3.22@sha256:a6695199ce879ae4bcfc92f3dfd55b7db5e46e3bdc128a690c6594444f0e300a AS runtime

# fix a problem with inotify instance limit
# https://stackoverflow.com/a/67111195
ENV DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE=false

# OpenTelemetry .NET automatic instrumentation 1.16.0, musl build for this Alpine image.
# The CLR profiler and the startup hook below activate it; OTEL_* environment variables configure it.
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) rid=linux-musl-x64; sum=4d95c3c4655c4fbdda7c64222c87b1c9224d80c5634017f121b0586511ea1c7d ;; \
      arm64) rid=linux-musl-arm64; sum=df0450477c37e4636d638a56f7eef0b49b7eed7047985a0fee87955e029c6a41 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q -O /tmp/otel-dotnet-auto.zip \
      "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v1.16.0/opentelemetry-dotnet-instrumentation-${rid}.zip"; \
    echo "${sum}  /tmp/otel-dotnet-auto.zip" | sha256sum -c -; \
    mkdir -p /otel-dotnet-auto; \
    unzip -q /tmp/otel-dotnet-auto.zip -d /otel-dotnet-auto; \
    rm /tmp/otel-dotnet-auto.zip; \
    ln -s "${rid}" /otel-dotnet-auto/native
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto \
    DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll \
    CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318} \
    CORECLR_PROFILER_PATH=/otel-dotnet-auto/native/OpenTelemetry.AutoInstrumentation.Native.so

RUN apk add --no-cache icu-libs \
    && apk upgrade --no-cache \
    && addgroup --system --gid 3369 easytrade \
    && adduser --system --ingroup easytrade --uid 3369 easytrade
USER easytrade:easytrade
WORKDIR /home/easytrade

COPY --from=build --chown=easytrade:easytrade ["/publish", "./"]

ENV ASPNETCORE_ENVIRONMENT=Development
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

ENTRYPOINT ["dotnet", "BrokerService.dll"]

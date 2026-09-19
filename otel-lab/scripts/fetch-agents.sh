#!/usr/bin/env bash
# Downloads the pinned official OpenTelemetry zero-code instrumentation packages into otel-lab/agents/
# (git-ignored). Every artifact is verified against a pinned SHA-256 before use.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$LAB_DIR/agents"
# shellcheck source=../versions.env
source "$LAB_DIR/versions.env"

verify() { echo "$2  $1" | sha256sum -c - >/dev/null; }

echo "== Java agent $OTEL_JAVA_AGENT_VERSION"
mkdir -p "$AGENTS/java"
JAR="$AGENTS/java/opentelemetry-javaagent.jar"
if [ ! -f "$JAR" ] || ! verify "$JAR" "$OTEL_JAVA_AGENT_SHA256"; then
  curl -fsSL -o "$JAR" "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_JAVA_AGENT_VERSION}/opentelemetry-javaagent.jar"
  verify "$JAR" "$OTEL_JAVA_AGENT_SHA256"
fi
echo "$OTEL_JAVA_AGENT_VERSION" > "$AGENTS/java/VERSION"

echo "== .NET automatic instrumentation $OTEL_DOTNET_VERSION (linux-musl-x64)"
mkdir -p "$AGENTS/dotnet"
ZIP="$AGENTS/opentelemetry-dotnet-instrumentation-linux-musl-x64-${OTEL_DOTNET_VERSION}.zip"
if [ ! -f "$ZIP" ] || ! verify "$ZIP" "$OTEL_DOTNET_MUSL_X64_SHA256"; then
  curl -fsSL -o "$ZIP" "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v${OTEL_DOTNET_VERSION}/opentelemetry-dotnet-instrumentation-linux-musl-x64.zip"
  verify "$ZIP" "$OTEL_DOTNET_MUSL_X64_SHA256"
fi
if [ ! -f "$AGENTS/dotnet/VERSION" ] || [ "$(cat "$AGENTS/dotnet/VERSION")" != "$OTEL_DOTNET_VERSION" ]; then
  rm -rf "$AGENTS/dotnet" && mkdir -p "$AGENTS/dotnet"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$AGENTS/dotnet"
fi
chmod -R a+rX "$AGENTS/dotnet"

echo "== Node.js auto-instrumentation packages (npm ci in node:${NODE_IMAGE_TAG})"
if [ ! -f "$AGENTS/node/package-lock.json" ]; then
  echo "package-lock.json missing; generating it (should be committed)"
  docker run --rm -v "$AGENTS/node:/w" -w /w "node:${NODE_IMAGE_TAG}" npm install --package-lock-only --ignore-scripts >/dev/null
fi
if [ ! -d "$AGENTS/node/node_modules/@opentelemetry/auto-instrumentations-node" ]; then
  docker run --rm -v "$AGENTS/node:/w" -w /w "node:${NODE_IMAGE_TAG}" npm ci --omit=dev --ignore-scripts >/dev/null
fi
chmod -R a+rX "$AGENTS/node"
echo "agents ready under $AGENTS"

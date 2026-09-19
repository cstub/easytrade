#!/usr/bin/env bash
# Shared environment for the lab scripts (sourced). Derives the image tag from the last commit that touched the
# application sources (src/ or compose.dev.yaml), with a -dirty suffix when those paths have uncommitted changes,
# so the tag documents exactly which source revision the images were built from.
LAB_DIR="${LAB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$LAB_DIR/.." && pwd)}"
lab_git_tag() {
  local sha dirty=""
  sha="$(git -C "$REPO_DIR" log -1 --format=%h --abbrev=12 -- src compose.dev.yaml)"
  if [ -n "$(git -C "$REPO_DIR" status --porcelain -- src compose.dev.yaml)" ]; then dirty="-dirty"; fi
  echo "${sha}${dirty}"
}
export LAB_DIR REPO_DIR
export LAB_PROJECT="${LAB_PROJECT:-easytrade-otel-lab}"
export LAB_HTTP_PORT="${LAB_HTTP_PORT:-8080}"
export LAB_NAMESPACE="${LAB_NAMESPACE:-easytrade-otel-lab}"
export LAB_BASE_URL="${LAB_BASE_URL:-http://127.0.0.1:${LAB_HTTP_PORT}}"
export LAB_IMAGE_TAG="${LAB_IMAGE_TAG:-$(lab_git_tag)}"

#!/usr/bin/env bash
# Build (and optionally push) one llama-swap+ComfyUI image.
#
#   ./scripts/build-image.sh v252-cuda-b10775
#   PUSH=true ./scripts/build-image.sh v252-cuda-b10775-non-root
#
# The upstream tag is the single source of truth: backend and root/non-root are
# derived from it, and the result is published under the identical tag name so
# `ghcr.io/<you>/llama-swap-comfyui:<tag>` always corresponds 1:1 to
# `ghcr.io/mostlygeek/llama-swap:<tag>`.

set -euo pipefail
cd "$(dirname "$0")/.."

# Both scripts cd to the repo root first, so point shellcheck's -x resolution
# at the parent of scripts/ rather than at scripts/ itself.
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=versions.env
source ./versions.env

TAG="${1:?usage: build-image.sh <upstream-tag> (e.g. v252-cuda-b10775)}"
PUSH="${PUSH:-false}"
# Whether this build may also claim the floating :<backend>[-non-root] alias.
# Set to false when backfilling an older build so the alias keeps pointing at
# the newest image.
PUSH_FLOATING="${PUSH_FLOATING:-true}"

backend_re="$(tr ' ' '|' <<<"$BACKENDS")"
if [[ ! "$TAG" =~ ^v([0-9]+)-(${backend_re})-b([0-9]+)(-non-root)?$ ]]; then
    echo "error: '${TAG}' is not a mirrorable upstream tag" >&2
    echo "       expected v<ver>-(${backend_re})-b<build>[-non-root]" >&2
    exit 1
fi
BACKEND="${BASH_REMATCH[2]}"
NON_ROOT="${BASH_REMATCH[4]}"

if [[ -n "$NON_ROOT" ]]; then
    TARGET_UID=10001; TARGET_GID=10001
else
    TARGET_UID=0; TARGET_GID=0
fi

torch_var="TORCH_INDEX_${BACKEND}"
TORCH_INDEX_URL="${!torch_var:?no torch index configured for backend ${BACKEND}}"

# Resolve the ComfyUI release to install unless one was pinned.
if [[ -z "${COMFYUI_REF:-}" ]]; then
    echo "==> resolving latest ComfyUI release"
    # Authenticate when we can: unauthenticated api.github.com is 60 req/h per
    # IP, and CI runners share IPs.
    auth=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    COMFYUI_REF="$(curl -fsSL "${auth[@]+"${auth[@]}"}" \
        https://api.github.com/repos/comfyanonymous/ComfyUI/releases/latest \
        | jq -r '.tag_name')"
    if [[ -z "$COMFYUI_REF" || "$COMFYUI_REF" == "null" ]]; then
        echo "error: could not resolve the latest ComfyUI release" >&2
        exit 1
    fi
fi

BASE_REF="${UPSTREAM_IMAGE}:${TAG}"
# The build-identified tag plus the floating alias upstream also maintains
# (:cuda, :cuda13-non-root, ...), so `docker pull ...:cuda` tracks the newest.
TARGET="${MIRROR_IMAGE}:${TAG}"
FLOATING="${MIRROR_IMAGE}:${BACKEND}${NON_ROOT}"

echo "==> building ${TARGET}"
echo "    base:    ${BASE_REF}"
echo "    comfyui: ${COMFYUI_REF}"
echo "    torch:   ${TORCH_INDEX_URL}"
echo "    user:    ${TARGET_UID}:${TARGET_GID}"

# --provenance=false matches upstream: the attestation manifest confuses the
# GHCR cleanup action into treating the real image as untagged.
build_args=(
    --provenance=false
    -f docker/comfyui.Containerfile
    --build-arg "BASE_IMAGE=${UPSTREAM_IMAGE}"
    --build-arg "BASE_TAG=${TAG}"
    --build-arg "BASE_REF=${BASE_REF}"
    --build-arg "TARGET_UID=${TARGET_UID}"
    --build-arg "TARGET_GID=${TARGET_GID}"
    --build-arg "COMFYUI_REF=${COMFYUI_REF}"
    --build-arg "COMFYUI_VERSION=${COMFYUI_REF}"
    --build-arg "COMFYUI_HOME=${COMFYUI_HOME}"
    --build-arg "COMFYUI_DATA=${COMFYUI_DATA}"
    --build-arg "TORCH_INDEX_URL=${TORCH_INDEX_URL}"
    -t "${TARGET}"
)
if [[ "$PUSH_FLOATING" == "true" ]]; then
    build_args+=(-t "${FLOATING}")
fi
build_args+=(.)

docker build "${build_args[@]}"

if [[ "$PUSH" == "true" ]]; then
    echo "==> pushing ${TARGET}"
    docker push "${TARGET}"
    if [[ "$PUSH_FLOATING" == "true" ]]; then
        echo "==> pushing ${FLOATING}"
        docker push "${FLOATING}"
    fi
else
    echo "==> PUSH is not 'true'; built locally only"
fi

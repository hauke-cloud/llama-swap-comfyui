#!/usr/bin/env bash
# Installs ComfyUI into $COMFYUI_HOME inside the image. Runs as root during the
# build; the Containerfile chowns the result to the target user afterwards.
set -euo pipefail

COMFYUI_HOME="${COMFYUI_HOME:-/opt/comfyui}"
COMFYUI_REF="${COMFYUI_REF:-}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
COMFYUI_REPO="${COMFYUI_REPO:-https://github.com/comfyanonymous/ComfyUI.git}"

if [[ -z "$COMFYUI_REF" ]]; then
    echo "COMFYUI_REF is required (the build resolves it from the latest release)" >&2
    exit 1
fi

echo "==> installing ComfyUI ${COMFYUI_REF} into ${COMFYUI_HOME}"
echo "    torch index: ${TORCH_INDEX_URL}"

git clone --depth 1 --branch "$COMFYUI_REF" "$COMFYUI_REPO" "${COMFYUI_HOME}/app"
COMFYUI_COMMIT="$(git -C "${COMFYUI_HOME}/app" rev-parse HEAD)"
rm -rf "${COMFYUI_HOME}/app/.git"

python3 -m venv "${COMFYUI_HOME}/venv"
PIP="${COMFYUI_HOME}/venv/bin/pip"

"$PIP" install --upgrade pip setuptools wheel

# Torch first, from the backend-specific index. ComfyUI's requirements.txt
# lists torch unpinned, so installing it up front means the generic PyPI
# resolver later sees the requirement as already satisfied and leaves the
# CUDA build in place instead of pulling the default one.
"$PIP" install --index-url "$TORCH_INDEX_URL" torch torchvision torchaudio

"$PIP" install -r "${COMFYUI_HOME}/app/requirements.txt"

# A build-time record of what actually landed, mirrored into an OCI label.
cat > "${COMFYUI_HOME}/VERSION" <<VERSION
comfyui_ref=${COMFYUI_REF}
comfyui_commit=${COMFYUI_COMMIT}
torch_index=${TORCH_INDEX_URL}
torch=$("${COMFYUI_HOME}/venv/bin/python" -c 'import torch; print(torch.__version__)')
python=$("${COMFYUI_HOME}/venv/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
VERSION

cat "${COMFYUI_HOME}/VERSION"

# pip's cache is disabled via PIP_NO_CACHE_DIR, but the venv still carries
# bytecode and test data that never gets read at runtime.
find "${COMFYUI_HOME}/venv" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "${COMFYUI_HOME}/venv" -name '*.pyc' -delete 2>/dev/null || true

echo "==> ComfyUI installed"

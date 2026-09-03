# Adds ComfyUI to an upstream llama-swap image, without changing anything else
# about it: same entrypoint, same user, same llama.cpp backend. ComfyUI is
# registered as a llama-swap model so the two share the GPU by swapping rather
# than by fighting over it.
#
# Built by scripts/build-image.sh -- see that script for the argument values.

ARG BASE_IMAGE=ghcr.io/mostlygeek/llama-swap
ARG BASE_TAG=cuda
FROM ${BASE_IMAGE}:${BASE_TAG}

# Upstream's non-root images already dropped to uid 10001, so claw root back
# for the install and hand it in again at the end.
USER 0:0

# Restored on the last line. 0/0 for the root variant, 10001/10001 for -non-root.
ARG TARGET_UID=0
ARG TARGET_GID=0

ARG COMFYUI_REF
ARG COMFYUI_HOME=/opt/comfyui
ARG COMFYUI_DATA=/data/comfyui
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

ENV COMFYUI_HOME=${COMFYUI_HOME} \
    COMFYUI_DATA=${COMFYUI_DATA} \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# python3-venv keeps ComfyUI's dependency tree out of the system interpreter,
# which matters because the base is a CUDA runtime image with its own packages.
# libgl1/libglib2.0-0 are the shared objects PyOpenGL and the imaging stack dlopen.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        libgl1 \
        libglib2.0-0 \
        python3 \
        python3-venv; \
    rm -rf /var/lib/apt/lists/*

COPY docker/install-comfyui.sh /usr/local/bin/install-comfyui.sh
RUN chmod +x /usr/local/bin/install-comfyui.sh && /usr/local/bin/install-comfyui.sh

# Keep upstream's config reachable; ours only adds the comfyui entry on top.
RUN cp /app/config.yaml /app/config.upstream.yaml
COPY docker/config.comfyui.yaml /app/config.yaml

RUN set -eux; \
    mkdir -p "${COMFYUI_DATA}"; \
    chown -R "${TARGET_UID}:${TARGET_GID}" "${COMFYUI_HOME}" "${COMFYUI_DATA}" /app/config.yaml

# Filled in by the build workflow from the resolved refs.
ARG BASE_REF
ARG COMFYUI_VERSION
LABEL org.opencontainers.image.title="llama-swap + ComfyUI" \
      org.opencontainers.image.description="llama-swap with ComfyUI installed and registered as a swappable model" \
      org.opencontainers.image.source="https://github.com/hauke-cloud/llama-swap-comfyui" \
      org.opencontainers.image.base.name="${BASE_REF}" \
      org.hauke-cloud.llama-swap-comfyui.base-image="${BASE_REF}" \
      org.hauke-cloud.llama-swap-comfyui.comfyui-version="${COMFYUI_VERSION}" \
      org.hauke-cloud.llama-swap-comfyui.torch-index="${TORCH_INDEX_URL}"

USER ${TARGET_UID}:${TARGET_GID}

# Entrypoint, workdir and healthcheck are inherited from upstream unchanged.

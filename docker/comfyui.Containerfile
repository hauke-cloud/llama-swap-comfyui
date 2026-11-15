# Adds ComfyUI and Strata to an upstream llama-swap image, without changing
# anything else about it: same entrypoint, same user, same llama.cpp backend.
# Both are registered as llama-swap models so everything shares the GPU by
# swapping rather than by fighting over it.
#
# Built by scripts/build-image.sh -- see that script for the argument values.

ARG BASE_IMAGE=ghcr.io/mostlygeek/llama-swap
ARG BASE_TAG=cuda
# Strata's published image for the matching CUDA flavor. Only its Terminal
# (bundled CPython + CLI + server) and engine package are copied out; both are
# self-contained and built on the same Ubuntu 24.04 as upstream's CUDA images.
ARG STRATA_IMAGE=ghcr.io/niko1221/strata
ARG STRATA_TAG=latest-cuda13

FROM ${STRATA_IMAGE}:${STRATA_TAG} AS strata

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
ARG STRATA_ROOT=/data/strata

# TRITON_CACHE_DIR is pinned because Triton otherwise writes its JIT output to
# $HOME/.triton, and the non-root variant's uid has no passwd entry -- so $HOME
# resolves to something unwritable. Under the data dir it is both writable and
# persistent, which also keeps the compile off the first request after a restart.
ENV COMFYUI_HOME=${COMFYUI_HOME} \
    COMFYUI_DATA=${COMFYUI_DATA} \
    TRITON_CACHE_DIR=${COMFYUI_DATA}/.triton \
    STRATA_ROOT=${STRATA_ROOT} \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# python3-venv keeps ComfyUI's dependency tree out of the system interpreter,
# which matters because the base is a CUDA runtime image with its own packages.
# libgl1/libglib2.0-0 are the shared objects PyOpenGL and the imaging stack dlopen.
#
# gcc + python3-dev are for Triton, which torch dispatches eager ops through
# (torch._native) -- not just torch.compile. On first use it builds its CUDA
# driver shim as a C extension at *runtime*, so without a compiler and Python.h
# in the image any workflow touching a Triton-backed op dies with
# "Failed to find C compiler".
#
# libatomic1/libgomp1/libnuma1/zlib1g are the system libraries Strata's engine
# package leaves to the OS (its SYSTEM-LIBS.txt); cudart/cublas come bundled.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        gcc \
        git \
        libatomic1 \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        libnuma1 \
        python3 \
        python3-dev \
        python3-venv \
        zlib1g; \
    rm -rf /var/lib/apt/lists/*

COPY docker/install-comfyui.sh /usr/local/bin/install-comfyui.sh
RUN chmod +x /usr/local/bin/install-comfyui.sh && /usr/local/bin/install-comfyui.sh

# Strata: Terminal + engine package from its own image, plus our wrappers.
# `strata` pins its state under $STRATA_ROOT; `strata-llama-swap` is what the
# llama-swap model entry runs (see docker/config.comfyui.yaml).
# --chown on the COPY rather than a later chown -R, which would duplicate the
# ~2-3 GB into another layer.
COPY --from=strata --chown=${TARGET_UID}:${TARGET_GID} /opt/strata/terminal /opt/strata/terminal
COPY --from=strata --chown=${TARGET_UID}:${TARGET_GID} /opt/strata/components /opt/strata/components
COPY docker/strata.sh /usr/local/bin/strata
COPY docker/strata-llama-swap.sh /usr/local/bin/strata-llama-swap
RUN chmod 0755 /usr/local/bin/strata /usr/local/bin/strata-llama-swap \
    && /opt/strata/terminal/bin/strata --version

# Keep upstream's config reachable; ours only adds the comfyui and strata
# entries on top.
RUN cp /app/config.yaml /app/config.upstream.yaml
COPY docker/config.comfyui.yaml /app/config.yaml

RUN set -eux; \
    mkdir -p "${COMFYUI_DATA}" "${STRATA_ROOT}"; \
    chown -R "${TARGET_UID}:${TARGET_GID}" "${COMFYUI_HOME}" "${COMFYUI_DATA}" "${STRATA_ROOT}" /app/config.yaml

# Filled in by the build workflow from the resolved refs.
ARG BASE_REF
ARG COMFYUI_VERSION
ARG STRATA_IMAGE
ARG STRATA_TAG
ARG STRATA_VERSION
ARG STRATA_ENGINE
LABEL org.opencontainers.image.title="llama-swap + ComfyUI + Strata" \
      org.opencontainers.image.description="llama-swap with ComfyUI and Strata installed and registered as swappable models" \
      org.opencontainers.image.source="https://github.com/hauke-cloud/llama-swap-comfyui" \
      org.opencontainers.image.base.name="${BASE_REF}" \
      org.hauke-cloud.llama-swap-comfyui.base-image="${BASE_REF}" \
      org.hauke-cloud.llama-swap-comfyui.comfyui-version="${COMFYUI_VERSION}" \
      org.hauke-cloud.llama-swap-comfyui.torch-index="${TORCH_INDEX_URL}" \
      org.hauke-cloud.llama-swap-comfyui.strata-image="${STRATA_IMAGE}:${STRATA_TAG}" \
      org.hauke-cloud.llama-swap-comfyui.strata-version="${STRATA_VERSION}" \
      org.hauke-cloud.llama-swap-comfyui.strata-engine="${STRATA_ENGINE}"

USER ${TARGET_UID}:${TARGET_GID}

# Entrypoint, workdir and healthcheck are inherited from upstream unchanged.

#!/bin/sh
# `strata` inside the image: Strata's Terminal, pointed at one fixed layout
# under $STRATA_ROOT so that llama-swap's model process and anything you run by
# hand (`docker exec <c> strata launch --status`) see the same presets, run
# settings, keys and model files.
#
# HOME and XDG_* are set unconditionally: Strata keeps its state there, and the
# non-root variant's uid has no passwd entry, so the inherited HOME is either
# unwritable or (for root) outside the volume and lost on an image update.
set -eu

root="${STRATA_ROOT:-/data/strata}"

export HOME="${root}/home"
export XDG_STATE_HOME="${root}/state"
export XDG_CONFIG_HOME="${root}/config"
export STRATA_INSTALL_DIR="${root}/install"
# Strata's own variable for where downloaded model files go.
export STRATA_DATA_DIR="${STRATA_DATA_DIR:-${root}/Strata-data}"
export STRATA_COMPONENTS_DIR="${STRATA_COMPONENTS_DIR:-/opt/strata/components}"
export LANG="${LANG:-C.UTF-8}" PYTHONUNBUFFERED=1 PYTHONNOUSERSITE=1

mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$STRATA_INSTALL_DIR" "$STRATA_DATA_DIR" 2>/dev/null || {
    echo "[X] ${root} is not writable by uid $(id -u). Mount a volume there (-v strata:${root}) owned by that uid." >&2
    exit 1
}

exec /opt/strata/terminal/bin/strata "$@"

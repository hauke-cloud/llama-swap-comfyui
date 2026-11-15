#!/bin/sh
# Runs Strata as a llama-swap model.
#
#   strata-llama-swap --port ${PORT} [--preset NAME] [strata launch flags...]
#   strata-llama-swap prepare        [--preset NAME] [strata launch flags...]
#
# `strata launch --no-tui` downloads/prepares the model, starts the server in
# the background and returns. llama-swap, however, needs one foreground process
# whose lifetime is the server's. So this script launches, then stays up while
# the server is ready, and on SIGTERM (llama-swap unloading the model) runs
# `strata launch --stop`, which drains requests and frees the GPU.
#
# `prepare` does the slow first-start work (a download of tens of GB, then
# preparing the model) outside llama-swap's health-check timeout: it launches on
# a scratch port, waits until the server is ready, and stops it again. The
# choices are saved in the preset, so the llama-swap entry starts in minutes.
#
# Any flag other than --port/--preset goes to `strata launch` unchanged, e.g.
# --model IQ3_XXS --context 64k --vision off. Given once, they are saved in the
# preset and reused by later starts.
set -u

STRATA=/usr/local/bin/strata
PYBIN=/opt/strata/terminal/python/bin/python3

say() { printf '[strata-llama-swap] %s\n' "$*"; }
die() { printf '[strata-llama-swap] error: %s\n' "$1" >&2; exit "${2:-1}"; }

mode=serve
if [ "${1:-}" = "prepare" ]; then mode=prepare; shift; fi

port=""
preset="llama-swap"
extra=0
# Pull --port/--preset out; everything else is passed through to launch.
n=$#
while [ "$n" -gt 0 ]; do
    arg="$1"; shift; n=$((n - 1))
    case "$arg" in
        --port)     [ "$n" -gt 0 ] || die "--port needs a value" 2; port="$1"; shift; n=$((n - 1)) ;;
        --port=*)   port="${arg#--port=}" ;;
        --preset)   [ "$n" -gt 0 ] || die "--preset needs a value" 2; preset="$1"; shift; n=$((n - 1)) ;;
        --preset=*) preset="${arg#--preset=}" ;;
        *)          set -- "$@" "$arg"; extra=1 ;;
    esac
done

if [ "$mode" = "prepare" ]; then
    port="${port:-18080}"
else
    [ -n "$port" ] || die "--port is required (llama-swap passes \${PORT})" 2
fi

# Refuse up front when the bundled engine cannot drive this GPU (no --gpus, or
# the driver is too old for the engine's CUDA), the way Strata's own container
# entrypoint does. Otherwise launch would go on to download tens of GB for a
# model that can never start.
if ! "$STRATA" components engine --output json 2>/dev/null | grep -q '"usable": *true'; then
    "$STRATA" components engine >&2 || true
    die "Strata's engine cannot use this GPU. Start the container with --gpus all (NVIDIA Container Toolkit); the cuda images need driver 575+, cuda13 580+." 3
fi

# Behind llama-swap, Strata sees the client's Host header (my-server:8080) and
# would refuse it as DNS rebinding. It only listens on 127.0.0.1 and llama-swap
# is the only thing in front of it, so accept any name unless told otherwise.
export STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-*}"

# A server left over from a previous run (e.g. the wrapper was SIGKILLed) would
# still hold the GPU and the preset; clear it first.
"$STRATA" launch --stop --preset "$preset" >/dev/null 2>&1 || true

if "$STRATA" launch --list-presets --output json 2>/dev/null | grep -q "\"name\": *\"${preset}\""; then
    set -- --preset "$preset" "$@"
    [ "$extra" = 1 ] && set -- "$@" --save-preset "$preset"
else
    set -- "$@" --save-preset "$preset"
fi
set -- launch --no-tui --access local --port "$port" --data-dir "${STRATA_DATA_DIR:-${STRATA_ROOT:-/data/strata}/Strata-data}" "$@"

stopping=""
launch_pid=""
# shellcheck disable=SC2317  # reached through the trap below
on_term() {
    stopping=1
    say "stop requested: stopping Strata (preset '${preset}')"
    if [ -n "$launch_pid" ] && kill -0 "$launch_pid" 2>/dev/null; then
        # Still downloading or loading: SIGINT makes launch stop what it started.
        kill -INT "$launch_pid" 2>/dev/null
        i=0; while kill -0 "$launch_pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
        kill -TERM "$launch_pid" 2>/dev/null || true
    fi
    "$STRATA" launch --stop --preset "$preset" || true
    exit 0
}
trap on_term TERM INT

# A background job of a non-interactive sh ignores SIGINT, which is how launch
# is told to stop cleanly; restore the default handler before exec'ing it.
RESET_INT='import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])'

say "starting: strata $*"
"$PYBIN" -c "$RESET_INT" "$STRATA" "$@" &
launch_pid=$!
wait "$launch_pid"
rc=$?
launch_pid=""
[ -n "$stopping" ] && exit 0
[ "$rc" -eq 0 ] || die "strata launch exited with code ${rc} (see the lines above)" "$rc"

if [ "$mode" = "prepare" ]; then
    say "preset '${preset}' is prepared; stopping the scratch server"
    "$STRATA" launch --stop --preset "$preset" || true
    exit 0
fi

say "serving on 127.0.0.1:${port}"

# Stay up while the server is; leave if it goes away so llama-swap notices.
bad=0
while [ -z "$stopping" ]; do
    sleep 5 &
    wait $!
    [ -n "$stopping" ] && break
    if "$STRATA" launch --status --output json 2>/dev/null | grep -q '"state": *"ready"'; then
        bad=0
    else
        bad=$((bad + 1))
    fi
    [ "$bad" -ge 3 ] && die "the Strata server is no longer running"
done
exit 0

#!/usr/bin/env bash
# Work out which upstream tags still need a ComfyUI image, and emit a GitHub
# Actions build matrix on stdout (JSON, one object per image to build).
#
#   ./scripts/plan-builds.sh            # normal diff against our package
#   FORCE=1 ./scripts/plan-builds.sh    # replan everything in range
#   BUILD_DEPTH=3 ./scripts/plan-builds.sh
#
# Writes a human-readable summary to stderr so workflow logs stay useful.

set -euo pipefail
cd "$(dirname "$0")/.."

# Both scripts cd to the repo root first, so point shellcheck's -x resolution
# at the parent of scripts/ rather than at scripts/ itself.
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=versions.env
source ./versions.env
# shellcheck source=scripts/lib-registry.sh
source ./scripts/lib-registry.sh

UPSTREAM_REPO="$(repo_path "$UPSTREAM_IMAGE")"
MIRROR_REPO="$(repo_path "$MIRROR_IMAGE")"
FORCE="${FORCE:-0}"

log() { printf '%s\n' "$*" >&2; }

# --- 1. read both tag lists -------------------------------------------------

log "==> listing tags for ${UPSTREAM_REPO}"
mapfile -t upstream_tags < <(ghcr_tags "$UPSTREAM_REPO")
log "    ${#upstream_tags[@]} upstream tags"

log "==> listing tags for ${MIRROR_REPO}"
mapfile -t mirror_tags < <(ghcr_tags "$MIRROR_REPO")
log "    ${#mirror_tags[@]} mirrored tags"

declare -A have=()
for t in ${mirror_tags[@]+"${mirror_tags[@]}"}; do have["$t"]=1; done

# --- 2. keep only the tags we mirror ---------------------------------------
#
# Upstream tag grammar: v<llama-swap ver>-<backend>-b<llama.cpp build>[-non-root]
# Floating tags (:cuda) and the unified-* family are deliberately excluded --
# they are aliases or a different image line, not build-identified releases.

backend_re="$(tr ' ' '|' <<<"$BACKENDS")"
tag_re="^v([0-9]+)-(${backend_re})-b([0-9]+)(-non-root)?$"

declare -a matched=()
for t in ${upstream_tags[@]+"${upstream_tags[@]}"}; do
    [[ "$t" =~ $tag_re ]] && matched+=("$t")
done

if [[ ${#matched[@]} -eq 0 ]]; then
    log "!!! no upstream tags matched ${tag_re} -- has the naming scheme changed?"
    printf '[]\n'
    exit 0
fi

# --- 3. select the most recent BUILD_DEPTH llama.cpp builds ------------------
#
# Upstream rebuilds twice a day, so "every tag ever" is thousands of images.
# A build is identified by the (llama-swap version, llama.cpp build) pair; we
# take the newest few of those and mirror every backend/variant within them.

mapfile -t recent_builds < <(
    for t in "${matched[@]}"; do
        [[ "$t" =~ $tag_re ]] || continue
        printf '%s %s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}"
    done | sort -k1,1nr -k2,2nr -u | head -n "$BUILD_DEPTH"
)

log "==> targeting the ${#recent_builds[@]} most recent upstream build(s):"
for b in "${recent_builds[@]}"; do log "    llama.cpp b${b%% *}, llama-swap v${b##* }"; done

# --- 4. expand to the concrete image list and drop what we already have -----

declare -a plan=()
newest_build="${recent_builds[0]}"
for b in "${recent_builds[@]}"; do
    build="${b%% *}"
    ver="${b##* }"
    # Only the newest build may move the floating :cuda / :cuda13 aliases --
    # a backfill of an older build must not drag them backwards.
    floating="false"
    [[ "$b" == "$newest_build" ]] && floating="true"
    # BACKENDS/VARIANTS are space-separated lists; splitting is the point.
    # shellcheck disable=SC2086
    for backend in $BACKENDS; do
        # shellcheck disable=SC2086
        for variant in $VARIANTS; do
            tag="v${ver}-${backend}-b${build}"
            [[ "$variant" == "non-root" ]] && tag="${tag}-non-root"

            # Not every backend/variant exists in every upstream run.
            if ! printf '%s\n' "${matched[@]}" | grep -qxF "$tag"; then
                log "    skip ${tag} (not published upstream)"
                continue
            fi
            if [[ "$FORCE" != "1" && -n "${have[$tag]:-}" ]]; then
                log "    skip ${tag} (already mirrored)"
                continue
            fi

            if [[ "$variant" == "non-root" ]]; then
                uid=10001; gid=10001
            else
                uid=0; gid=0
            fi

            torch_var="TORCH_INDEX_${backend}"
            plan+=("$(jq -cn \
                --arg tag "$tag" \
                --arg backend "$backend" \
                --arg variant "$variant" \
                --arg uid "$uid" \
                --arg gid "$gid" \
                --arg torch "${!torch_var}" \
                --arg floating_tag "${backend}$([[ $variant == non-root ]] && echo -non-root)" \
                --arg push_floating "$floating" \
                '{tag:$tag, backend:$backend, variant:$variant, uid:$uid, gid:$gid,
                  torch_index:$torch, floating_tag:$floating_tag,
                  push_floating:$push_floating}')")
        done
    done
done

if [[ ${#plan[@]} -gt $MAX_BUILDS ]]; then
    log "!!! ${#plan[@]} builds planned, capping at MAX_BUILDS=${MAX_BUILDS}"
    plan=("${plan[@]:0:$MAX_BUILDS}")
fi

log "==> ${#plan[@]} image(s) to build"
if [[ ${#plan[@]} -eq 0 ]]; then
    printf '[]\n'
    exit 0
fi
printf '%s\n' "${plan[@]}" | jq -sc '.'

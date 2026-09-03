#!/usr/bin/env bash
# Shared GHCR helpers. Source this, don't execute it.
#
# GHCR speaks the plain OCI distribution API, so listing tags needs no
# packages:read scope and works anonymously for public packages. That matters
# because upstream publishes on a cron, not on releases -- polling the registry
# is the only way to see a new tag the moment it lands.

: "${REGISTRY:=ghcr.io}"

# ghcr_token <repository>  e.g. ghcr_token mostlygeek/llama-swap
#
# Anonymous for public packages; authenticates with GITHUB_TOKEN when set so
# the same helper also reads our own (possibly private) package.
ghcr_token() {
    local repo="$1"
    local url="https://${REGISTRY}/token?scope=repository:${repo}:pull&service=${REGISTRY}"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL -u "x:${GITHUB_TOKEN}" "$url" | jq -r '.token'
    else
        curl -fsSL "$url" | jq -r '.token'
    fi
}

# ghcr_tags <repository>
#
# Prints every tag, one per line. Follows the RFC 5988 Link header: GHCR caps a
# page at 1000 tags and llama-swap is already past 4900, so an unpaginated read
# silently returns only the oldest slice.
ghcr_tags() {
    local repo="$1"
    local token path headers body next

    token="$(ghcr_token "$repo")"
    path="/v2/${repo}/tags/list?n=1000"

    while [[ -n "$path" ]]; do
        headers="$(mktemp)"
        body="$(mktemp)"

        # A package that has never been pushed 404s with NAME_UNKNOWN. That is
        # the expected state on the very first mirror run, so stay quiet.
        if ! curl -fsL -D "$headers" -o "$body" \
            -H "Authorization: Bearer ${token}" \
            "https://${REGISTRY}${path}" 2>/dev/null; then
            rm -f "$headers" "$body"
            return 0
        fi

        jq -r '.tags // [] | .[]' <"$body"

        next="$(grep -i '^link:' "$headers" | sed -E 's/.*<([^>]+)>.*/\1/' || true)"
        rm -f "$headers" "$body"

        [[ "$next" == "$path" ]] && break
        path="$next"
    done
}

# ghcr_digest <repository> <tag>
#
# Prints the manifest digest, or nothing when the tag does not exist. Used to
# detect an upstream retag: same tag name, new content.
ghcr_digest() {
    local repo="$1" tag="$2" token
    token="$(ghcr_token "$repo")"
    curl -fsSL -o /dev/null -D - \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY}/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}'
}

# repo_path <image-reference>  ghcr.io/foo/bar -> foo/bar
repo_path() {
    printf '%s\n' "${1#"${REGISTRY}"/}"
}

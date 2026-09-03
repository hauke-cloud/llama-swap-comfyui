# llama-swap-comfyui

Automatically mirrors every CUDA image released by
[mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap) and republishes
it with **ComfyUI** installed and wired into llama-swap as a swappable model.

```
ghcr.io/mostlygeek/llama-swap:v252-cuda-b10775
              │
              │  + python venv + torch (cu128) + ComfyUI
              ▼
ghcr.io/hauke-cloud/llama-swap-comfyui:v252-cuda-b10775
```

Tag names are identical to upstream's, so any upstream tag maps 1:1 onto ours.

## Why this needs polling, not a release hook

Upstream does not cut a GitHub release per container image. A cron workflow
rebuilds against the newest `ggml-org/llama.cpp` server image twice a day
(12:00 and 18:00 UTC) and pushes tags shaped like:

```
v<llama-swap version>-<backend>-b<llama.cpp build>[-non-root]
        v252         -  cuda   -   b10775        -non-root
```

There is no event to subscribe to. So [`scripts/plan-builds.sh`](scripts/plan-builds.sh)
reads upstream's tag list straight from the OCI distribution API, diffs it
against our own package, and emits a build matrix. The schedule runs at 14:30
and 20:30 UTC — two hours behind upstream, so the new tags have landed.

## What gets built

| | |
|---|---|
| Backends | `cuda` (CUDA 12.8, torch `cu128`), `cuda13` (CUDA 13.3, torch `cu130`) |
| Variants | root (uid 0) and `-non-root` (uid 10001), matching upstream |
| Per run | 4 images, from the single newest upstream build |
| Floating tags | `:cuda`, `:cuda13`, `:cuda-non-root`, `:cuda13-non-root` |

**Only the CUDA backends.** ComfyUI needs PyTorch, and of upstream's seven
backends only the CUDA ones have a first-class wheel index. `vulkan`, `musa` and
`cpu` would get CPU-only torch; `intel` would need the separate XPU index. Both
are a config change away — see [Extending the matrix](#extending-the-matrix).

## Using it

```bash
docker run --rm --gpus all \
  -p 8080:8080 \
  -v /srv/models:/models \
  -v /srv/comfyui:/data/comfyui \
  ghcr.io/hauke-cloud/llama-swap-comfyui:cuda
```

- **llama-swap** — `http://localhost:8080/` (OpenAI-compatible API + UI)
- **ComfyUI** — `http://localhost:8080/upstream/comfyui/`

Hitting the ComfyUI path starts it on demand, the same way an inference request
starts an LLM. Because ComfyUI shares llama-swap's default exclusive group with
every llama.cpp model, **loading ComfyUI unloads the resident LLM and vice
versa** — one GPU, one workload at a time, which is the whole reason to run
ComfyUI under llama-swap instead of beside it. It unloads itself 15 minutes
after the last request (`ttl: 900`).

### Layout

| Path | What |
|---|---|
| `/opt/comfyui/app` | ComfyUI checkout |
| `/opt/comfyui/venv` | its virtualenv (torch lives here) |
| `/opt/comfyui/VERSION` | exact refs and torch version that were installed |
| `/data/comfyui` | **mount this** — models, custom nodes, input, output, user |
| `/app/config.yaml` | llama-swap config, watched for changes |
| `/app/config.upstream.yaml` | upstream's original example config |

`/data/comfyui` is passed to ComfyUI as `--base-directory`, so everything
mutable is under that one mount. On the `-non-root` images it is owned by
10001:10001.

### Adding your own models

`/app/config.yaml` ships with only the `comfyui` entry. Mount your own over it:

```bash
-v ./my-config.yaml:/app/config.yaml:ro
```

llama-swap runs with `-watch-config`, so edits are picked up live. Keep the
`comfyui` block from [`docker/config.comfyui.yaml`](docker/config.comfyui.yaml)
when you write your own.

### Knowing what is inside an image

Every image records its provenance as OCI labels:

```console
$ docker inspect ghcr.io/hauke-cloud/llama-swap-comfyui:cuda \
    -f '{{json .Config.Labels}}' | jq 'with_entries(select(.key|startswith("org.hauke-cloud")))'
{
  "org.hauke-cloud.llama-swap-comfyui.base-image": "ghcr.io/mostlygeek/llama-swap:v252-cuda-b10775",
  "org.hauke-cloud.llama-swap-comfyui.comfyui-version": "v0.34.0",
  "org.hauke-cloud.llama-swap-comfyui.torch-index": "https://download.pytorch.org/whl/cu128"
}
```

## Repository layout

```
versions.env                      all tunables in one place
docker/
  comfyui.Containerfile           FROM upstream, + ComfyUI, restore user
  install-comfyui.sh              clone + venv + torch + requirements
  config.comfyui.yaml             llama-swap config with the comfyui model
scripts/
  lib-registry.sh                 paginated GHCR tag/digest reads
  plan-builds.sh                  upstream tags - our tags = build matrix
  build-image.sh                  build/push one tag
.github/workflows/
  mirror.yml                      cron: plan -> build -> push -> cleanup
  ci.yml                          shellcheck, hadolint, config schema, planner,
                                  and a real build when docker/ changes
```

## Operating it

Everything runs locally with the same scripts CI uses.

```bash
# What would the next scheduled run build?
GITHUB_TOKEN=$(gh auth token) ./scripts/plan-builds.sh | jq

# Build one tag locally (no push)
./scripts/build-image.sh v252-cuda-b10775

# Build and push
PUSH=true ./scripts/build-image.sh v252-cuda-b10775
```

Manual runs via **Actions → Mirror upstream + ComfyUI → Run workflow** take:

| Input | Use |
|---|---|
| `build_depth` | cover more than the newest upstream build, e.g. after an outage |
| `comfyui_ref` | pin a specific ComfyUI ref instead of the latest release |
| `force` | rebuild tags that are already mirrored (e.g. a new ComfyUI release) |

### ComfyUI versioning

Each run resolves `comfyanonymous/ComfyUI`'s latest GitHub release **once**, so
every image in a run holds the same ComfyUI, and stamps it into a label. To
rebuild the current upstream tags against a newer ComfyUI without waiting for a
new llama.cpp build, run the workflow with `force: true`.

### Extending the matrix

`BACKENDS` in [`versions.env`](versions.env) drives everything — the tag regex,
the matrix, and the per-backend torch index. To add one, append it to `BACKENDS`
and add a matching `TORCH_INDEX_<backend>`:

```sh
BACKENDS="cuda cuda13 rocm"
TORCH_INDEX_rocm="https://download.pytorch.org/whl/rocm6.3"
```

`intel` needs `https://download.pytorch.org/whl/xpu`; `vulkan`, `musa` and `cpu`
have no accelerated build and would take `https://download.pytorch.org/whl/cpu`.

Note the runner budget: a CUDA base is ~6 GB unpacked and the torch layer adds
~4 GB, against ~14 GB free on a stock hosted runner. The workflow reclaims ~25 GB
before building, which comfortably fits one image — but the matrix runs
`max-parallel: 1` for that reason.

## Caveats

- **Not a verbatim mirror.** These are derived images. If you want byte-identical
  copies of upstream, pull upstream.
- **Upstream's tag grammar is a contract we don't control.** If it changes, the
  planner matches nothing; CI's `plan` job fails loudly rather than letting a
  scheduled run quietly mirror zero images.
- **`amd64` only**, because upstream's CUDA images are.
- **Old tags are pruned.** The cleanup step keeps the 40 most recent tags.
- **No custom nodes are baked in.** Install them into the mounted
  `/data/comfyui/custom_nodes` so they survive an image update.

## Licence

The tooling in this repository is MIT. The images it produces contain
[llama-swap](https://github.com/mostlygeek/llama-swap) (MIT),
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and
[ComfyUI](https://github.com/comfyanonymous/ComfyUI) (GPL-3.0) under their own
licences; ComfyUI's GPL-3.0 governs redistribution of the resulting image.

<!-- llm-readme-management spec=1 commit=a7a35baff935d5806b61ffa11c8fdd268de0669e template=default model=qwen3.6-35b-a3b digest=598d66067ca0 generated=2026-09-08T21:21:19Z -->
<a href="https://hauke.cloud" target="_blank"><img src="https://img.shields.io/badge/home-hauke.cloud-brightgreen" alt="hauke.cloud" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud" target="_blank"><img src="https://img.shields.io/badge/github-hauke.cloud-blue" alt="hauke.cloud Github Organisation" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud/llm-readme-management" target="_blank"><img src="https://img.shields.io/badge/template-default-orange" alt="Repository type - default" style="display: block;" /></a>


# Llama Swap Comfyui


<img src="https://raw.githubusercontent.com/hauke-cloud/.github/main/resources/img/organisation-logo-small.png" alt="hauke.cloud logo" width="109" height="123" align="right">


<llm header>

This repository provides a GitHub Actions workflow that builds derived container images extending the upstream llama-swap service. It installs ComfyUI as a swappable model alongside llama.cpp LLMs, allowing you to share a single GPU between OpenAI-compatible text generation and image-generation workflows.

</llm>


## :book: Description

<llm description>

This repository provides container images that extend `mostlygeek/llama-swap` by integrating ComfyUI as a swappable model alongside llama.cpp LLMs. You can use these images to run GPU-accelerated inference on a single GPU, switching between serving OpenAI-compatible language model requests and generating images via ComfyUI. The system ensures exclusive GPU access; loading one model unloads the other.

The repository mirrors upstream `llama-swap` tags and builds derived images for every new release. Each image installs ComfyUI with the matching PyTorch backend, registers it as a llama-swap model entry, and supports automatic cleanup of old tags. You can deploy these images to share a GPU between text generation and image workflows without manual intervention.

* Mirrors upstream `llama-swap` tags and builds derived images with ComfyUI and PyTorch.
* Registers ComfyUI as a swappable model that shares the GPU exclusively with llama.cpp.
* Supports CUDA 12.8 and CUDA 13.3 backends with floating aliases for latest builds.
* Includes a scheduled cleanup job to retain only the most recent tagged manifests.

</llm>


## 🚀 Getting started

<llm getting_started hint="Assume nothing about the ecosystem beyond what the analysis names. If the repository has no build step, say what a reader does with it instead.">

1. You clone and enter the repository.
```bash
git clone https://github.com/hauke-cloud/llama-swap-comfyui.git
cd llama-swap-comfyui
```
2. You validate the service configuration against the upstream schema.
```bash
pip install check-jsonschema pyyaml && curl -fsSL -o /tmp/config-schema.json https://raw.githubusercontent.com/mostlygeek/llama-swap/refs/heads/main/config-schema.json && check-jsonschema --schemafile /tmp/config-schema.json docker/config.comfyui.yaml
```
3. You generate a build matrix to identify available upstream tags.
```bash
GITHUB_TOKEN=<token> FORCE="1" ./scripts/plan-builds.sh | jq -e 'length > 0'
```
4. You build a single container image locally.
```bash
./scripts/build-image.sh <tag>
```
5. You start the container with GPU access and persistent data directories.
```bash
docker run --rm --gpus all -p 8080:8080 -v /srv/models:/models -v /srv/comfyui:/data/comfyui ghcr.io/hauke-cloud/llama-swap-comfyui:cuda
```

</llm>


## :airplane: Usage

<llm usage>

Once you have pulled a built image, run it with Docker to expose the llama-swap API on port 8080. Mount your model directory and a persistent data volume so ComfyUI retains custom nodes and caches across restarts.

```bash
docker run --rm --gpus all -p 8080:8080 -v /srv/models:/models -v /srv/comfyui:/data/comfyui ghcr.io/hauke-cloud/llama-swap-comfyui:cuda
```

You can also start the service locally using the provided `docker-compose.yaml` file, which handles GPU reservations and volume mounts automatically.

```bash
docker compose up
```

The container exposes an OpenAI-compatible endpoint for llama.cpp models and a ComfyUI interface on the same port. When you send requests to either backend, llama-swap loads the corresponding model into VRAM and unloads the other. ComfyUI automatically frees the GPU after 15 minutes of idle time (`ttl: 900`). To add custom nodes or persist workflows, place them in the mounted `/data/comfyui` directory. The service watches `config.comfyui.yaml` for live updates, so you can adjust health checks, logging, or model routing without restarting the container.

</llm>


## 📄 License

This Project is licensed under the GNU General Public License v3.0

- see the [LICENSE](LICENSE) file for details.


## :coffee: Contributing

To become a contributor, please check out the [CONTRIBUTING](CONTRIBUTING.md) file.


## :email: Contact

For any inquiries or support requests, please open an issue in this
repository or contact us at [contact@hauke.cloud](mailto:contact@hauke.cloud).

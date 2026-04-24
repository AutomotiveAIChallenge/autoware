# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a fork of the Autoware meta-repository customized for the Automotive AI Challenge (AIC) with AWSIM. It is a **meta-repo**: workspace sources are pulled in via `autoware.repos` / `simulator.repos` into `src/` by `vcs import`, not committed here. Published Docker images live at `ghcr.io/automotiveaichallenge/autoware-universe`.

## Common commands

Host setup (one-time):
```bash
./setup-dev-env.sh                        # full dev env via ansible
./setup-dev-env.sh -y --runtime universe  # runtime-only (used inside Docker)
```

Source import + build (standard Autoware workspace flow; run from repo root):
```bash
mkdir -p src && vcs import src < autoware.repos
rosdep update && rosdep install -y --from-paths src --ignore-src --rosdistro humble
source /opt/ros/humble/setup.bash
colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release
colcon test --packages-select <pkg> && colcon test-result --verbose
```

Docker builds (see `docker/build.sh`):
```bash
./docker/build.sh                         # builds devel/prebuilt/runtime (always --no-nvidia)
./docker/build.sh --platform linux/arm64
./docker/build.sh --clean-cache           # force full rebuild (default reuses BuildKit cache)
```

`build.sh` は Dockerfile ビルド後に自動で `docker/slim.sh --mode buildable` を実行し、`:humble-latest-runtime` / `:humble-latest` を 6.5 GB まで絞り込む。colcon build 可能性は維持。

torch cu121 は bundled `nvidia-*` pip パッケージ経由で GPU 推論可能。`/usr/local/cuda` を要する Autoware C++ TensorRT ノードはサポート外。

`pre-commit` is the lint gate (see `.github/workflows/pre-commit*.yaml`); run `pre-commit run -a` locally.

## Docker architecture (critical)

`docker/autoware-universe/Dockerfile` is a 4-stage multi-stage build: `base` → `devel` → `prebuilt`, and `runtime` branches **directly from `base`** (not `devel`). See `docker/reduce.md` for the full rationale. **Invariants that must not be broken:**

1. **`runtime` derives from `base`, never from `devel`/`prebuilt`.** Docker union FS cannot physically delete lower-layer content with `rm -rf`; branching from `devel` drags in the `src/` layer (~3.3 GB) and heavy pip deps (~6 GB) permanently.
2. **Heavy pip/apt/COPY belong in `devel` only.** Anything added in `base` propagates to `runtime`. `requirements.txt` (torch, nvidia, ultralytics, …) is installed in `devel`. The `runtime` stage installs only `torch==2.3.1` + cu121 for GPU inference.
3. **Cleanup must happen in the same `RUN` as the layer it cleans.** A later `RUN rm -rf …` does not shrink earlier layers.
4. **`runtime` copies only `/autoware/install/` from `prebuilt`**, then strips binaries, deletes headers/`*.a`/`*.la`, large `*.onnx` (>10 MB), `__pycache__`, docs/man/locale/icons/fonts, `/usr/lib/{gcc,jvm,llvm*}`.
5. **ansible setuptools patch**: the Dockerfile `sed`-patches `setup-dev-env.sh` to replace `pipx install "ansible==6.*"` with `python3 -m pip install` — the pipx venv lacks setuptools, which breaks `ansible.builtin.pip` (imports `pkg_resources`). Because the universe playbook uses `connection: local`, `ANSIBLE_PYTHON_INTERPRETER` cannot override this. Do not revert the sed patch.
6. **BuildKit cache mounts** (`/var/cache/apt`, `/var/lib/apt/lists`, `/root/.cache/pip`) keep apt/pip downloads out of final layers while enabling incremental rebuilds. `docker-clean` is removed and `Keep-Downloaded-Packages "true"` is set so the cache mount actually persists. `Install-Recommends "false"` is **not** set globally (breaks ansible); `--no-install-recommends` is applied only on explicit `apt-get install` calls.
7. `.dockerignore` at repo root excludes `build/`, `install/`, `log/`, `src/`, `.git/` — do not add them back; context transfer would balloon to ~5 GB.

Tags published by `build.sh`: `:$rosdistro-latest-{devel,prebuilt,runtime}[-cuda]` on `ghcr.io/automotiveaichallenge/autoware-universe`.

## GPU vs CPU runtime

The default build produces a `runtime` image that can run torch on GPU when started with `--gpus all` (cu121 userspace libs are bundled; host supplies the driver). Autoware C++ nodes themselves don't import torch/ultralytics under `--no-nvidia`, which is why pip deps were safely moved out of `base`. To re-enable full GPU Autoware (TensorRT YOLO etc.), reverse the steps listed in `docker/reduce.md` §"運用上の注意".

## Env / distro

`amd64.env` / `arm64.env` pin `rosdistro=humble`, `rmw_implementation=rmw_cyclonedds_cpp`, and base images. `build.sh` sources the matching file based on target platform.

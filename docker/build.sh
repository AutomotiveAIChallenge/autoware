#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
WORKSPACE_ROOT="$SCRIPT_DIR/../"

# Parse arguments
args=()
while [ "$1" != "" ]; do
    case "$1" in
    --platform)
        option_platform="$2"
        shift
        ;;
    --clean-cache)
        # Force a full rebuild, ignoring BuildKit layer/cache-mount state.
        option_clean_cache=true
        ;;
    *)
        args+=("$1")
        ;;
    esac
    shift
done

# Set platform
if [ -n "$option_platform" ]; then
    platform="$option_platform"
else
    platform="linux/amd64"
    if [ "$(uname -m)" = "aarch64" ]; then
        platform="linux/arm64"
    fi
fi

# Load env
source "$WORKSPACE_ROOT/amd64.env"
if [ "$platform" = "linux/arm64" ]; then
    source "$WORKSPACE_ROOT/arm64.env"
fi

# https://github.com/docker/buildx/issues/484
export BUILDKIT_STEP_LOG_MAX_SIZE=10000000

# Reuse BuildKit layer cache + apt/pip cache mounts by default.
# Pass --clean-cache to force a full rebuild.
cache_flag=()
if [ "$option_clean_cache" = "true" ]; then
    cache_flag+=("--no-cache")
fi

# Always build the slim --no-nvidia variant. torch cu121 is self-contained via
# bundled nvidia-* pip packages, so /usr/local/cuda is unnecessary. Autoware C++
# TensorRT/CUDA nodes are intentionally unsupported in this image.
set -x
docker buildx bake --allow=ssh "${cache_flag[@]}" --load --progress=plain -f "$SCRIPT_DIR/autoware-universe/docker-bake.hcl" \
    --set "*.context=$WORKSPACE_ROOT" \
    --set "*.ssh=default" \
    --set "*.platform=$platform" \
    --set "*.args.ROS_DISTRO=$rosdistro" \
    --set "*.args.BASE_IMAGE=$base_image" \
    --set "devel.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-devel" \
    --set "prebuilt.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-prebuilt" \
    --set "runtime.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-runtime-raw"
set +x

# Post-process: flatten + apt purge of items that Dockerfile cleanup cannot
# physically delete (union FS whiteouts don't reclaim lower-layer bytes).
# Produces the canonical `:humble-latest-runtime` and `:humble-latest` tags.
RUNTIME_RAW="ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-runtime-raw"
RUNTIME_FINAL="ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-runtime"
LATEST_ALIAS="ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest"

"$SCRIPT_DIR/slim.sh" --mode buildable "$RUNTIME_RAW" "$RUNTIME_FINAL"
docker tag "$RUNTIME_FINAL" "$LATEST_ALIAS"
docker rmi "$RUNTIME_RAW" >/dev/null 2>&1 || true

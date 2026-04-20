#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
WORKSPACE_ROOT="$SCRIPT_DIR/../"

# Parse arguments
args=()
while [ "$1" != "" ]; do
    case "$1" in
    --no-nvidia)
        option_no_nvidia=true
        ;;
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

# Set CUDA options
if [ "$option_no_nvidia" = "true" ]; then
    setup_args="--no-nvidia"
    image_name_suffix=""
else
    setup_args="--no-cuda-drivers"
    image_name_suffix="-cuda"
fi

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

set -x
docker buildx bake "${cache_flag[@]}" --load --progress=plain -f "$SCRIPT_DIR/autoware-universe/docker-bake.hcl" \
    --set "*.context=$WORKSPACE_ROOT" \
    --set "*.ssh=default" \
    --set "*.platform=$platform" \
    --set "*.args.ROS_DISTRO=$rosdistro" \
    --set "*.args.BASE_IMAGE=$base_image" \
    --set "*.args.SETUP_ARGS=$setup_args" \
    --set "devel.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-devel$image_name_suffix" \
    --set "prebuilt.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-prebuilt$image_name_suffix" \
    --set "runtime.tags=ghcr.io/automotiveaichallenge/autoware-universe:$rosdistro-latest-runtime$image_name_suffix"
set +x

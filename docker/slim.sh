#!/usr/bin/env bash
# docker/slim.sh — post-process image slimmer via export/import flatten.
#
# Why flatten: apt-get purge / rm in a derived stage creates union FS whiteouts
# but does NOT reclaim bytes from lower layers. `docker export | docker import`
# writes the current filesystem state into a single new layer, physically
# dropping deleted content. Metadata (CMD/ENV/WORKDIR/etc.) is preserved by
# reading it from the source image and passing --change on import.
#
# Usage:
#   ./docker/slim.sh [--mode buildable|ml-only] [<source-tag>] [<output-tag>]
#     --mode buildable (default): colcon build still works afterwards
#     --mode ml-only: aggressive — strips C/C++ toolchain, ROS headers,
#                     dev libs. Only python + torch + rclpy runtime survives.
#     default source = ghcr.io/automotiveaichallenge/autoware-universe:humble-latest-runtime
#     default output = <source>-<mode>

set -euo pipefail

MODE="buildable"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
    --mode)
        MODE="$2"
        shift 2
        ;;
    *)
        args+=("$1")
        shift
        ;;
    esac
done
SRC="${args[0]:-ghcr.io/automotiveaichallenge/autoware-universe:humble-latest-runtime}"
DST="${args[1]:-${SRC}-${MODE}}"
[[ $MODE =~ ^(buildable|ml-only)$ ]] || {
    echo "invalid --mode: $MODE"
    exit 2
}

echo "==> Source: $SRC"
echo "==> Output: $DST"

# Metadata to preserve across flatten.
mapfile -t CHANGES < <(
    docker inspect --format '
{{- range .Config.Env }}ENV {{ . }}
{{ end -}}
{{- range $k, $v := .Config.Labels }}LABEL {{ $k }}={{ $v }}
{{ end -}}
WORKDIR {{ .Config.WorkingDir }}
USER {{ .Config.User }}
ENTRYPOINT {{ json .Config.Entrypoint }}
CMD {{ json .Config.Cmd }}
{{ range $p, $_ := .Config.ExposedPorts }}EXPOSE {{ $p }}
{{ end }}' "$SRC" | sed '/^WORKDIR $/d; /^USER $/d; /^ENTRYPOINT null$/d; /^CMD null$/d; /^$/d'
)

CID=$(docker create --entrypoint sleep "$SRC" infinity)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

echo "==> Running cleanup inside container…"
docker start "$CID" >/dev/null

# Cleanup list. "buildable" keeps C/C++ toolchain + ROS headers so downstream
# `colcon build` still works. "ml-only" rips out the toolchain for ML-only
# use where colcon is never invoked afterwards.
docker exec -e MODE="$MODE" "$CID" bash -c '
set -eux

# 1) Safe apt purges — things colcon build never needs. No wildcard globs
#    (they cascade via --auto-remove and break python / ros packages).
apt-get update -y || true
apt-mark manual \
  python3 python3-minimal libpython3.10 \
  ros-humble-rclpy ros-humble-ros-core ros-humble-ros-base \
  ros-humble-ament-package python3-ament-package \
  2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
  openjdk-17-jre-headless openjdk-17-jdk-headless \
  default-jre default-jre-headless \
  || true

if [ "$MODE" = "ml-only" ]; then
  # Aggressive: strip C/C++ toolchain and dev libs. ROS Python bindings still
  # work (they only need the .so libs already installed). colcon build fails
  # after this — do not use this variant for Autoware-building workflows.
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    gcc-11 g++-11 cpp-11 binutils \
    cmake cmake-data \
    libboost1.74-dev libgdal-dev libopenblas-dev libcgal-dev \
    libllvm11 libllvm14 libllvm15 \
    libclang-cpp14 libclang1-14 \
    linux-libc-dev \
    || true
fi

apt-get autoremove -y --purge || true
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# 2) JVM data directories (Autoware runtime never invokes Java).
#    NOTE: /usr/lib/llvm-* is intentionally preserved — Mesa swrast/llvmpipe
#    links libLLVM.so, so removing it breaks OpenGL software rendering on
#    CPU-only hosts (rviz2 falls back to llvmpipe when NVIDIA is absent).
rm -rf /usr/lib/jvm /usr/share/java 2>/dev/null || true

# 3) Intentionally DO NOT sweep .a / .la under /opt/ros/humble.
#    rviz_ogre_vendor exports OgreGLSupport.a etc. via CMake targets — removing
#    them breaks downstream find_package(rviz_ogre_vendor). Total <10 MB.

if [ "$MODE" = "ml-only" ]; then
  # Purge headers + remaining static libs system-wide. Breaks colcon build.
  rm -rf /usr/include /usr/local/include /opt/ros/humble/include 2>/dev/null || true
  find /usr -xdev -type f \( -name "*.a" -o -name "*.la" \) -delete 2>/dev/null || true
fi

# 4) __pycache__ everywhere.
find / -xdev -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true

# 5) Non-English locales.
shopt -s extglob
rm -rf /usr/share/locale/!(en|en_US|C) 2>/dev/null || true
shopt -u extglob
rm -rf /tmp/* /root/.cache /var/tmp/* 2>/dev/null || true

echo "=== remaining top-level sizes (mode=$MODE) ==="
du -sh /usr/* /opt/* /autoware/* /root/* 2>/dev/null | sort -rh | head -15
' || {
    echo "cleanup failed"
    exit 1
}

docker stop "$CID" >/dev/null

echo "==> Exporting + importing (flatten)…"
change_args=()
for c in "${CHANGES[@]}"; do
    change_args+=(--change "$c")
done

docker export "$CID" | docker import "${change_args[@]}" - "$DST"

SRC_SIZE=$(docker image inspect "$SRC" --format '{{.Size}}')
DST_SIZE=$(docker image inspect "$DST" --format '{{.Size}}')
printf '\n==> Size: %s (src) -> %s (dst, -%s)\n' \
    "$(numfmt --to=iec "$SRC_SIZE")" \
    "$(numfmt --to=iec "$DST_SIZE")" \
    "$(numfmt --to=iec "$((SRC_SIZE - DST_SIZE))")"

echo "==> Smoke test: torch + rclpy + colcon/gcc availability"
docker run --rm --entrypoint bash "$DST" -c '
  source /opt/ros/humble/setup.bash
  [ -f /autoware/install/setup.bash ] && source /autoware/install/setup.bash
  python3 -c "import torch; print(\"torch:\", torch.__version__)"
  python3 -c "import rclpy; rclpy.init(); print(\"rclpy OK\")"
  which gcc-11 g++-11 cmake colcon
  test -d /opt/ros/humble/include && echo "ros headers OK"
  test -d /usr/include/c++ && echo "c++ headers OK"
' || echo "⚠ smoke test failed — inspect before using"

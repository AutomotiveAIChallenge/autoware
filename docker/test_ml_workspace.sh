#!/usr/bin/env bash
# Test whether a base image supports aichallenge-racingkart's ML training
# workflow (torch GPU + tiny_lidar_net model construction + training step).
#
# Runs entirely via `docker run` (no racingkart build needed) and uses
# synthetic data so no rosbag/dataset is required.

set -euo pipefail

IMG="${1:-ghcr.io/automotiveaichallenge/autoware-universe:humble-latest}"
RACINGKART="${RACINGKART_DIR:-$HOME/aichallenge-racingkart}"
ML_WS="$RACINGKART/aichallenge/ml_workspace"

[ -d "$ML_WS/tiny_lidar_net" ] || { echo "ml_workspace not found at $ML_WS"; exit 1; }
[ -f /tmp/ml_smoke.py ] || { echo "/tmp/ml_smoke.py missing"; exit 1; }

echo "==> Image: $IMG"
docker image inspect "$IMG" --format 'size: {{.Size}} bytes' | numfmt --to=iec --field=2 -- || true

docker run --rm --gpus all \
  -v "$ML_WS:/aichallenge/ml_workspace:ro" \
  -v /tmp/ml_smoke.py:/tmp/ml_smoke.py:ro \
  --entrypoint bash \
  "$IMG" -c '
    set -e
    echo "=== pip install extras ==="
    python3 -m pip install --quiet --no-cache-dir \
      hydra-core omegaconf tensorboard h5py jaxtyping tqdm 2>&1 | tail -5
    echo "=== smoke run ==="
    python3 /tmp/ml_smoke.py
  '

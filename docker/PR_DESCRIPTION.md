# Reduce Docker image size while preserving colcon + ML training workflows

## Summary

`ghcr.io/automotiveaichallenge/autoware-universe:humble-latest` を **13.8 GB → 7.56 GB（−45%）** に削減。`aichallenge-racingkart` 下流の `colcon build` / AWSIM 起動 / ml_workspace の PyTorch 学習が全て動作することを実機で確認済。

## Motivation

- `humble-latest` (旧 13.8 GB) は `/usr/local/cuda-11.6` (~3.9 GB、torch は pip 経由 `nvidia-*` で自己完結しているため未使用)、pipx ansible venv (~422 MB)、`/usr/share/doc` (~160 MB)、および Docker union FS の下層レイヤーで whiteout'd されたが物理削除されていないデータを多量に含んでいた。
- 下流の `aichallenge-racingkart` は ML 学習 (pytorch) + Autoware ノードビルド + AWSIM シミュレータを同じベースイメージの上で走らせる。軽量化に伴い必要な apt 依存が暗黙に切れていたため、packages.txt を拡充して build 可用性を保証。

## Changes

### `docker/autoware-universe/Dockerfile`
- **CUDA toolkit を強制削除**: `setup-dev-env.sh --no-nvidia` をビルドスクリプトで固定し、base stage の同一 RUN で `rm -rf /usr/local/cuda*` を実行（union FS レイヤー原則により、同一 RUN でないと物理削除されない）。
- **runtime cleanup の保守的化**: `/usr/lib/gcc`（cc1 等を含む）、`/usr/include`（libstdc++ の `bits/` を含む）、`/opt/ros/humble/include`、`/autoware/install/*/include`、全 `.a` ファイルを保持。これらは下流 `colcon build` が参照するため。
- **pipx ansible venv の正しいパスを cleanup**: 既存の `/root/.local/pipx` はパス誤りで 422 MB 残っていた → `/root/.local/share/pipx` を追加。
- **追加 cleanup**: `/root/.ansible`, `/usr/share/doc-base`, `/usr/share/info`。
- `ARG SETUP_ARGS` 廃止（常に `--no-nvidia`）。

### `docker/build.sh`
- `--no-nvidia` オプションと `-cuda` サフィックス付きタグ生成を廃止（torch cu121 は pip 同梱 `nvidia-*` で完全自己完結するため CUDA 変種は存在意義がない）。
- Dockerfile ビルド直後に `docker/slim.sh --mode buildable` を自動実行。
- `:humble-latest` を `:humble-latest-runtime` のエイリアスとして付与（racingkart 等の下流互換性のため）。
- BuildKit の `--allow=ssh` 明示対応。

### `docker/slim.sh` (新規)
`docker export | docker import` による flatten で、Docker union FS では物理削除できないサイズを回収する後処理スクリプト。
- `--mode buildable` (default): colcon build 可用性を維持。`openjdk-*`, `/usr/lib/jvm`, `__pycache__`, 非英語 locale のみ削除。`/usr/lib/llvm-*` は Mesa の swrast/llvmpipe が `libLLVM.so` に動的リンクしているため保持（CPU-only インスタンスで rviz2 をソフトウェアレンダリング起動する際に必要）。
- `--mode ml-only`: さらに C/C++ toolchain とヘッダーも削除（ML 学習専用、rclpy は削除される）。
- 主要な cascading 事故を防ぐため `apt-mark manual` で `python3 / rclpy / ros-humble-ros-core` 等を保護。

### `docker/test_ml_workspace.sh` (新規)
ml_workspace の tiny_lidar_net パイプライン相当（torch GPU + TinyLidarNet 構築 + forward/backward/optim 5 step）を実データなしで回す smoke test。

### `packages.txt` (拡充)
`--no-nvidia` 化に伴い暗黙に欠落していた apt パッケージを明示追加:
- ROS runtime/tooling: `ros-humble-xacro`, `ros-humble-topic-tools`, `ros-humble-nav2-msgs`
- rviz2 系: `ros-humble-rviz2` + `rviz-common` / `rviz-default-plugins` / `rviz-rendering` / `rviz-ogre-vendor` / `rviz-assimp-vendor` （`autoware_overlay_rviz_plugin` が `ament_auto_find_build_dependencies` 経由で rviz_common 側の `find_dependency(Qt5)` に依存して `qt5_wrap_cpp` を取得する、暗黙の推移的連鎖を成立させるため）
- Qt5 dev: `qtbase5-dev`, `qttools5-dev`
- 地理測地: `libgeographic-dev`, `geographiclib-tools`
- その他: `libboost-dev`, `python3-plotly`

### `.github/workflows/update-docker-manifest.yaml`
`latest-cuda` / `latest-prebuilt-cuda` エイリアスジョブ削除。

### `docker/reduce.md` / `CLAUDE.md`
運用注意と不変条件を更新。

## Image size comparison

| イメージ | Before | After | 削減 |
| --- | --- | --- | --- |
| **`ghcr.io/.../autoware-universe:humble-latest`** | **13.8 GB** | **7.56 GB** | **−6.24 GB (−45%)** |
| `humble-latest-runtime` (= `humble-latest`) | 13.8 GB | 7.56 GB | −45% |
| `humble-latest-devel` | 13.8 GB | ~12.0 GB | −13% |
| `humble-latest-prebuilt` | — | 16.6 GB | (新規タグ) |
| aichallenge-racingkart `aichallenge-2025-dev` (下流) | 旧 13.8GB ベース | 8.91 GB | — |

## Verified items

### Upstream (awsim-autoware)
- [x] `./docker/build.sh` が成功 (`humble-latest-runtime` = 7.56 GB)
- [x] `slim.sh --mode buildable` が自動実行され `.a` と C/C++ toolchain を保持
- [x] `ARG SETUP_ARGS` 廃止後も CI `docker-build-and-push-main.yaml` が動く (matrix の `setup-args` は以後 no-op)
- [x] torch 2.3.1+cu121 が `import torch; torch.cuda.is_available()` で `True`（RTX 2080 Ti 実機確認）
- [x] gcc-11 / g++-11 / cc1 / Scrt1.o / crti.o が揃っており `echo 'int main(){}' | gcc -xc -` がリンクまで通る
- [x] `#include <rclcpp/rclcpp.hpp>` が `/opt/ros/humble/include/rclcpp` から解決
- [x] `/autoware/install/autoware_auto_control_msgs/include` 等の Autoware パッケージヘッダーが保持
- [x] `/usr/local/cuda*` が存在しない（torch の ldd で `libcudart.so.12` が `/usr/local/lib/python3.10/dist-packages/nvidia/cuda_runtime/lib/` から解決されることを確認）
- [x] `/root/.local/share/pipx` が削除済（422 MB 回収）
- [x] `/usr/share/doc` / `doc-base` / `info` / 非英語 locale 削除済

### Downstream (aichallenge-racingkart)
- [x] `./docker_build.sh dev` 成功 → `aichallenge-2025-dev:latest` (8.91 GB) ビルド
- [x] `make autoware-build` で `colcon build` が 22/22 packages 成功（エラーゼロ、stderr 出力は ament の "header install destination" 警告のみ）
- [x] `make dev` で AWSIM + Autoware の 2 コンテナ起動、20 秒以上連続稼働
- [x] `ros2 node list` で Autoware ノード群が登録済（ekf_localizer, gyro_odometer, mpc_controller, racing_kart_gnss_poser, rviz2 等）
- [x] `ros2 topic list` で AWSIM 連携 topic (`/awsim/control_cmd`, `/awsim/state` 等) と Autoware 制御 topic (`/control/command/control_cmd` 等) が publish されている
- [x] `make down` でクリーンシャットダウン

### ML training (ml_workspace/tiny_lidar_net) — GPU 実機
- [x] `python3 train.py` が Hydra config を正しく読み込み
- [x] `MultiSeqConcatDataset` で複数シーケンスを ConcatDataset 化（2 train seq + 1 val seq, 1000/200 samples）
- [x] CUDA device (RTX 2080 Ti) 認識、`.to(device)` 成功
- [x] Train/Val ループ 3 epochs 完走（15 iter/epoch × 3 + 4 val iter）
- [x] Loss 0.7513 → 0.6118 へ単調減少（学習が実際に進んでいる）
- [x] `best_model.pth` / `last_model.pth` 保存成功（`/tmp/ckpts/`）
- [x] `convert_weight.py --model tinylidarnet --ckpt best_model.pth` が `weights/converted_weights.npy` を出力（deploy 用の .pth→.npy 変換）
- [x] `hydra-core`, `omegaconf`, `tensorboard`, `h5py`, `hdf5plugin`, `jaxtyping`, `tqdm`, `rosbags` の import がすべて通る

### 3 variant smoke test (GPU 学習 forward/backward) — 参考
| Variant | Size | colcon build | rclpy | ML 学習 (GPU) |
| --- | --- | --- | --- | --- |
| A: Dockerfile のみ | 8.99 GB | ✅ | ✅ | ✅ |
| B: slim.sh `--mode buildable` (本 PR 採用) | 6.5-7.6 GB | ✅ | ✅ | ✅ |
| C: slim.sh `--mode ml-only` | 5.9 GB | ❌ | ❌ | ✅ |

## Test plan

- [x] `./docker/build.sh --clean-cache` (フレッシュビルド) で 7.56 GB の runtime image が生成される
- [x] `aichallenge-racingkart` で `./docker_build.sh dev && make autoware-build && make dev` がエラーなく完走
- [x] `docker run --gpus all aichallenge-2025-dev:latest python3 /aichallenge/ml_workspace/tiny_lidar_net/train.py ...` で実学習が回る
- [x] `ros2 node list` / `ros2 topic list` で Autoware + AWSIM の通信を確認
- [ ] GHCR に push して外部 CI / 参加者が新サイズの `humble-latest` を pull できること（別 PR で実施予定、権限調整待ち）

## Known caveats

1. **Autoware C++ の TensorRT/CUDA ノードはサポート外**: `--no-nvidia` 固定のため、tensorrt_yolo / lidar_centerpoint 等の CUDA ベースノードは実行不可。pytorch は pip 同梱 `nvidia-*` で動作する。必要になった場合は `docker/reduce.md` の巻き戻し手順を参照。
2. **slim.sh は下流が `apt install` を再実行しても動くよう `/var/lib/apt/lists` を再取得可能な状態で保持**: ただし `apt-mark manual` による保護リストに無い `ros-humble-*` を purge する際はカスケードに注意。
3. **`.a` / headers は意図的に保持**: `rviz_ogre_vendor` が `libOgreGLSupport.a` を `IMPORTED` target として export する CMake 設定があるため。削除すると下流 CMake が "file does not exist" で fail する（実機で再現確認済）。

## References

- `docker/reduce.md` — 本作業の経緯と Docker union FS 原則の詳説
- `docker/slim.sh` — flatten 方式の後処理スクリプト
- `docker/test_ml_workspace.sh` — ml_workspace 用 smoke test

# Docker Image 軽量化 + 高速化メモ

## サイズ削減結果

| イメージ                         | Before      | After (Dockerfile) | After (+ slim.sh) | 最終削減           |
| -------------------------------- | ----------- | ------------------ | ----------------- | ------------------ |
| **runtime** (= `:humble-latest`) | **13.8 GB** | **8.99 GB**        | **6.5 GB**        | **−7.3 GB (−53%)** |
| devel                            | 13.8 GB     | 12.1 GB            | —                 | −1.7 GB (−12%)     |

`build.sh` は Dockerfile ビルド後に自動で `slim.sh --mode buildable` を実行し、最終 `:humble-latest-runtime` / `:humble-latest` を生成する。

## slim.sh の mode

- **`--mode buildable`** (default, デフォルト採用): colcon build 可能性を維持。gcc-11, g++-11, cmake, /usr/include, /opt/ros/humble/include, libboost*-dev, libgdal-dev, libopenblas-dev を保持。openjdk / JVM / `__pycache__` / 非英語 locale を削除。`/usr/lib/llvm-*` は CPU ホストでの Mesa swrast / rviz2 ソフトウェアレンダリングに必要なため保持 → **6.5-7.6 GB**
- **`--mode ml-only`**: ML 学習専用。上記に加えて C/C++ toolchain と全ヘッダーを削除。rclpy もカスケードで消える（ROS 実行不可）。ML 学習コードは `rosbags` pip パッケージ経由で bag 読込するため影響なし → **5.9 GB**

## 動作検証

各 variant で `docker/test_ml_workspace.sh` により ML 学習 smoke test (torch GPU, TinyLidarNet モデル構築, 5-step 学習ループ) が PASS。

> runtime には torch (cu121) を含めて GPU 推論を可能にしている。torch と同梱 CUDA ライブラリを外せば 3.81 GB まで落とせる。

## 変更ファイル

- `.dockerignore` (リポジトリルート、新規)
- `docker/autoware-universe/Dockerfile` (書き換え)
- `docker/build.sh` (更新)

## 効いた施策 (効果順)

### 1. `pip install` を base → devel に移動 (最大の効果)

- 重量級 pip 依存 (torch 1.6 GB + nvidia 2.8 GB + triton 420 MB + 他) を `devel` 専用に
- `runtime` は `base` から直派生するためこれらのレイヤーを継承しない
- `--no-nvidia` ビルドでは Autoware の C++ は torch/ultralytics を import していないことを確認済
- → pip 分 約 6 GB 丸ごと runtime から除外

### 2. `runtime` を `devel` ではなく `base` から派生

- Docker union FS の特性上、`rm -rf` では下層レイヤーを物理削除できない
- `vcs import src` (3.3 GB) を含む `devel` の系譜から切り離すことで src レイヤー除去
- → 約 3.3 GB 削減

### 3. runtime stage で積極的な cleanup

- `strip --strip-unneeded` でバイナリからシンボル削除
- ONNX モデル (10 MB 超) 削除 — `tensorrt_yolo` の YOLO v3/v4/v5 全種 = 約 1.14 GB
- ヘッダー (`*.h`, `*.hpp`)、静的ライブラリ (`*.a`, `*.la`)、docs、doc-base、man、info、locale、icons、fonts、gcc、jvm、llvm 削除
- `__pycache__`、`*.pyc` 削除
- pipx ansible venv (`/root/.local/share/pipx` 422 MB) と `/root/.ansible` 削除 — setup-dev-env.sh は sed パッチで pip install に切替えているが、pipx venv 本体は別経路で残存するため明示削除
- `/var/log/*` 削除
- **`--no-nvidia` 固定化**: CUDA 変種の publish を廃止
  - torch cu121 は `nvidia-cu12` pip パッケージから全ての CUDA .so を解決するため、`/usr/local/cuda-11.6` (3.9 GB) は pytorch 動作には不要
  - Autoware C++ の TensorRT/CUDA ノードは動作しなくなるが、本プロジェクトでは pytorch 動作のみ保証すれば十分
  - `build.sh` から `--no-nvidia` オプションと `-cuda` サフィックスタグを削除、`Dockerfile` は `setup-dev-env.sh --no-nvidia` 固定
  - `update-docker-manifest.yaml` から `latest-cuda` / `latest-prebuilt-cuda` エイリアス生成ジョブを削除

### 4. `.dockerignore`

- `build/`、`install/`、`log/`、`src/`、`.git/` 除外
- ビルドコンテキスト転送 5 GB → ほぼ 0

### 5. BuildKit キャッシュマウント

- apt (`/var/cache/apt`、`/var/lib/apt/lists`) と pip (`/root/.cache/pip`) に `--mount=type=cache,sharing=locked`
- `docker-clean` を削除し `Keep-Downloaded-Packages "true"` で .deb キャッシュ保持
- 備考: `Install-Recommends "false"` のグローバル設定は ansible が壊れるため未採用。`--no-install-recommends` は明示的 apt 呼び出しのみに限定

### 6. `build.sh` の `--no-cache` を撤去

- デフォルトでキャッシュ活用
- `--clean-cache` オプションで明示的に強制再ビルド可

## 副次バグ修正: ansible setuptools 問題

- `setup-dev-env.sh` の `pipx install --force "ansible==6.*"` は venv に `setuptools` を同梱しない
- その結果、`ansible.builtin.pip` タスク (gdown インストール) が `ModuleNotFoundError: pkg_resources` で失敗
- universe playbook は `connection: local` のため `ANSIBLE_PYTHON_INTERPRETER` では上書き不能
- `pipx inject` は `/autoware/ansible/` ディレクトリを path と誤検知して失敗
- **対処**: Dockerfile 内で sed パッチを当て、`pipx install` → `python3 -m pip install "ansible==6.*"` に置換。system pip → system Python → setuptools 完備、で ansible が正常に動作

## ビルド時間 (フレッシュビルド、キャッシュ無し)

| ステップ                | 所要時間     |
| ----------------------- | ------------ |
| setup-dev-env.sh        | ~150 s       |
| apt (packages.txt)      | ~10 s        |
| pip install (devel 内)  | ~90 s        |
| vcs + rosdep install    | ~90 s        |
| colcon build            | ~10 分       |
| runtime strip + cleanup | ~5 s         |
| **合計**                | **約 20 分** |

再ビルド時は apt/pip キャッシュマウントが効くため、これらのダウンロード分が省略される。

## 動作確認済み項目

```bash
docker run --rm --entrypoint bash ghcr.io/automotiveaichallenge/autoware-universe:humble-latest-runtime -c '
  source /autoware/install/setup.bash
  ros2 pkg list | wc -l      # => 412
  python3 -c "import rclpy; rclpy.init()"  # => rclpy OK
'
```

- ROS 2 パッケージ 412 個認識
- Autoware/tier4/behavior 系パッケージ 74 個
- `rclpy init` 成功 (strip したバイナリも問題なくロード)
- numpy / pyyaml 動作 (apt/ROS 経由で入るため残存)

## 運用上の注意

- この runtime image は **GPU 推論 (torch / ultralytics / 大きな ONNX) を使う Autoware ノードを動かせません**
- GPU 版ビルドに切替える場合の巻き戻し手順:
  1. `Dockerfile` の `requirements.txt` インストール箇所を `devel` から `base` に戻す
  2. runtime の cleanup から `torch*`、`nvidia*`、`triton*` 等の Python 削除ブロックと `find ... -name "*.onnx" -size +10M -delete` を外す
  3. `build.sh` から `--no-nvidia` を外す
- numpy / pyyaml 等の基本 Python ライブラリは apt / ROS 側で入るため削除対象外

## アーキテクチャ不変条件

Dockerfile の多段構成で絶対に守る必要がある条件:

1. **`runtime` は `base` から派生する**。`devel` から派生させると、src レイヤー (3.3 GB) や pip パッケージ (6 GB) が union FS に残り削除しても消えない
2. **重量級の pip/apt/COPY は devel に閉じ込める**。base に置くと runtime に流れる
3. **cleanup は追加するレイヤーと同一 RUN で実行する**。別 RUN の `rm -rf` は下層レイヤーを削除しない

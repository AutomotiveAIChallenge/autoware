# hadolint global ignore=DL3006,DL3008
ARG BASE_IMAGE

# ==============================================================================
# base: OS + ROS + system/pip deps + GPU vendor registrations.
# Shared by devel and runtime, so runtime does NOT inherit the src layer.
FROM $BASE_IMAGE AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

# Let BuildKit own the apt caches so that downloaded .deb archives and
# package lists do NOT inflate the final image.
# (Install-Recommends is intentionally left on globally because
#  setup-dev-env.sh / ansible depends on several Recommends packages.)
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Minimal tools needed before setup-dev-env.sh runs (ssh-keyscan, vcs over ssh).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ssh \
  && mkdir -p ~/.ssh \
  && ssh-keyscan github.com >> ~/.ssh/known_hosts

# Set up ROS and system dependencies via ansible.
COPY setup-dev-env.sh ansible-galaxy-requirements.yaml amd64.env arm64.env /autoware/
COPY ansible/ /autoware/ansible/
WORKDIR /autoware
# ansible 6.x in a pipx venv lacks setuptools, which breaks
# ansible.builtin.pip (it imports pkg_resources). The universe playbook
# uses `connection: local`, so ansible runs modules with its own Python
# (the pipx venv), ignoring ANSIBLE_PYTHON_INTERPRETER.
# Workaround: install ansible system-wide so its Python is /usr/bin/python3,
# which already has setuptools (from apt python3-setuptools).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    sed -i 's|^pipx install --include-deps --force "ansible==6\.\*"$|python3 -m pip install "ansible==6.*"|' setup-dev-env.sh \
  && ./setup-dev-env.sh -y --runtime --no-nvidia universe \
  && python3 -m pip uninstall -y ansible ansible-core || true

# Extra apt packages. These are shared by devel and runtime.
# Heavy pip packages go into the devel stage only (see below) so that
# they do NOT end up as layers of the runtime image.
COPY packages.txt /autoware/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    clean_packages=$(grep -vE '^\s*#' packages.txt | sed '/^\s*$/d' || true); \
    if [ -n "$clean_packages" ]; then \
      apt-get update; \
      export DEBIAN_FRONTEND=noninteractive; \
      echo "$clean_packages" | xargs -r -t apt-get install -y --no-install-recommends; \
    fi

# Register Vulkan / GLVND / OpenCL GPU vendors + drop unused repo lists.
ADD --chmod=644 "https://gitlab.com/nvidia/container-images/vulkan/raw/dc389b0445c788901fda1d85be96fd1cb9410164/nvidia_icd.json" /etc/vulkan/icd.d/nvidia_icd.json
ADD --chmod=644 "https://gitlab.com/nvidia/container-images/opengl/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json" /etc/glvnd/egl_vendor.d/10_nvidia.json
RUN mkdir -p /etc/OpenCL/vendors \
  && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd \
  && chmod 644 /etc/OpenCL/vendors/nvidia.icd \
  && rm -rf /etc/apt/sources.list.d/cuda*.list \
            /etc/apt/sources.list.d/docker.list \
            /etc/apt/sources.list.d/nvidia-docker.list

# ==============================================================================
# devel: base + heavy pip deps + Autoware src + rosdep-resolved deps.
FROM base AS devel

# Heavy pip packages (torch, nvidia, ultralytics, plotly, pandas, ...) are
# installed here so they ship with devel/prebuilt but NOT with runtime.
COPY requirements.txt /autoware/
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install -r requirements.txt

COPY autoware.repos /autoware/autoware.repos
RUN --mount=type=ssh \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    mkdir -p src \
  && vcs import src < autoware.repos \
  && rosdep update \
  && DEBIAN_FRONTEND=noninteractive rosdep install -y \
       --ignore-src --from-paths src --rosdistro "$ROS_DISTRO"

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]

# ==============================================================================
# prebuilt: devel + colcon-built artifacts (for quick try-out).
FROM devel AS prebuilt
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN source /opt/ros/"$ROS_DISTRO"/setup.bash \
  && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release \
  && find /autoware/install -type d -exec chmod 777 {} \;

RUN echo "source /autoware/install/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]

# ==============================================================================
# runtime: base + compiled install tree + torch (with bundled CUDA for GPU).
# No src layer; binaries stripped; headers/static libs/docs removed.
FROM base AS runtime
ARG ROS_DISTRO

# torch with cu121 wheels — bundled CUDA userspace libs make
# `torch.cuda.is_available()` work when the container is run with
# `docker run --gpus all` and the host has NVIDIA drivers. Installed in the
# runtime stage (not base) so other heavy pip deps do not bleed in.
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cu121 \
      torch==2.3.1 torchvision==0.18.1 torchaudio==2.3.1

COPY --from=prebuilt /autoware/install/ /autoware/install/

RUN set -eux; \
    find /autoware/install -type f \( -executable -o -name "*.so*" \) \
         -exec strip --strip-unneeded --remove-section=.comment --remove-section=.note {} + 2>/dev/null || true; \
    # NOTE: .a / .la files under /opt/ros and /autoware intentionally preserved.
    # rviz_ogre_vendor ships libOgreGLSupport.a as a required static library
    # referenced by its exported CMake targets; downstream colcon builds fail
    # at CMake time if it is missing. Total footprint is <10 MB, not worth
    # the reproducibility risk.
    # Headers intentionally preserved: /usr/include (libstdc++ bits/),
    # /opt/ros/humble/include (rclcpp/), and /autoware/install/*/include
    # (autoware_auto_msgs, tier4_autoware_utils, ...) are required by
    # downstream `colcon build` in aichallenge-racingkart and similar consumers.
    # Bundled ONNX models inside Autoware packages: delete large ones.
    # --no-nvidia builds cannot run TensorRT inference against them.
    find /autoware/install -type f -name "*.onnx" -size +10M -delete; \
    find /autoware/install -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true; \
    find /autoware/install -type f -name "*.pyc" -delete; \
    # Usual cleanup.
    rm -rf \
      /autoware/ansible \
      /autoware/ansible-galaxy-requirements.yaml \
      /autoware/setup-dev-env.sh \
      /autoware/*.env \
      /autoware/packages.txt \
      /autoware/requirements.txt \
      /autoware/autoware.repos \
      /root/.local/pipx \
      /root/.local/share/pipx \
      /root/.ansible \
      /root/.cache \
      /usr/share/doc \
      /usr/share/doc-base \
      /usr/share/man \
      /usr/share/info \
      /usr/share/locale \
      /usr/share/icons \
      /usr/share/backgrounds \
      /usr/share/fonts \
      /usr/lib/jvm \
      /usr/lib/llvm* \
      /var/log/*

RUN echo "source /autoware/install/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]

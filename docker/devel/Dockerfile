# Image args should come at the beginning.
ARG BASE_IMAGE="ubuntu:22.04"
ARG PREBUILT_BASE_IMAGE
# hadolint ignore=DL3006
FROM $BASE_IMAGE as devel
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO="humble"
ARG SETUP_ARGS

## Install apt packages
# hadolint ignore=DL3008
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
  git \
  ssh \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

## Copy files
COPY autoware.repos setup-dev-env.sh ansible-galaxy-requirements.yaml amd64.env arm64.env /autoware/
COPY ansible/ /autoware/ansible/
WORKDIR /autoware
RUN ls /autoware

## Add GitHub to known hosts for private repositories
RUN mkdir -p ~/.ssh \
  && ssh-keyscan github.com >> ~/.ssh/known_hosts

## Set up development environment
RUN --mount=type=ssh \
  ./setup-dev-env.sh -y $SETUP_ARGS universe \
  && pip uninstall -y ansible ansible-core

RUN --mount=type=ssh,uid=1000 \
  mkdir src \
  && vcs import src < autoware.repos
  
RUN rosdep update \
  && DEBIAN_FRONTEND=noninteractive rosdep install -y --ignore-src --from-paths src --rosdistro "$ROS_DISTRO" -r \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

## Clean up unnecessary files
RUN rm -rf \
  "$HOME"/.cache \
  /etc/apt/sources.list.d/cuda*.list \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/nvidia-docker.list

## Register Vulkan GPU vendors
RUN curl https://gitlab.com/nvidia/container-images/vulkan/raw/dc389b0445c788901fda1d85be96fd1cb9410164/nvidia_icd.json -o /etc/vulkan/icd.d/nvidia_icd.json \
  && chmod 644 /etc/vulkan/icd.d/nvidia_icd.json
RUN curl https://gitlab.com/nvidia/container-images/opengl/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json -o /etc/glvnd/egl_vendor.d/10_nvidia.json \
  && chmod 644 /etc/glvnd/egl_vendor.d/10_nvidia.json

## Register OpenCL GPU vendors
RUN mkdir -p /etc/OpenCL/vendors \
  && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd \
  && chmod 644 /etc/OpenCL/vendors/nvidia.icd

## Create entrypoint
# hadolint ignore=DL3059
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]
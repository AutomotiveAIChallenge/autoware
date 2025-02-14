# hadolint global ignore=DL3006,DL3008
ARG BASE_IMAGE

# ==============================================================================
FROM $BASE_IMAGE as devel
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO
ARG SETUP_ARGS

# Install apt packages
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
  git \
  ssh \
  && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/* "$HOME"/.cache

# Add GitHub to known hosts for private repositories
RUN mkdir -p ~/.ssh \
  && ssh-keyscan github.com >> ~/.ssh/known_hosts

# Copy files
COPY autoware.repos setup-dev-env.sh ansible-galaxy-requirements.yaml amd64.env arm64.env /autoware/
COPY ansible/ /autoware/ansible/
WORKDIR /autoware

# Set up development environment
RUN --mount=type=ssh \
  ./setup-dev-env.sh -y --runtime $SETUP_ARGS universe \
  && pip uninstall -y ansible ansible-core \
  && mkdir src \
  && vcs import src < autoware.repos \
  && rosdep update \
  && DEBIAN_FRONTEND=noninteractive rosdep install -y --ignore-src --from-paths src --rosdistro "$ROS_DISTRO" \
  && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/* "$HOME"/.cache

# Clean up unnecessary files
RUN rm -rf \
  /etc/apt/sources.list.d/cuda*.list \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/nvidia-docker.list

# Register Vulkan GPU vendors
ADD "https://gitlab.com/nvidia/container-images/vulkan/raw/dc389b0445c788901fda1d85be96fd1cb9410164/nvidia_icd.json" /etc/vulkan/icd.d/nvidia_icd.json
RUN chmod 644 /etc/vulkan/icd.d/nvidia_icd.json
ADD "https://gitlab.com/nvidia/container-images/opengl/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json" /etc/glvnd/egl_vendor.d/10_nvidia.json
RUN chmod 644 /etc/glvnd/egl_vendor.d/10_nvidia.json

# Register OpenCL GPU vendors
RUN mkdir -p /etc/OpenCL/vendors \
  && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd \
  && chmod 644 /etc/OpenCL/vendors/nvidia.icd

# ==============================================================================
FROM devel as prebuilt
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build and change permission for runtime data conversion
RUN source /opt/ros/"$ROS_DISTRO"/setup.bash \
  && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release \
  && find /autoware/install -type d -exec chmod 777 {} \;

# Create entrypoint
RUN echo "source /autoware/install/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]

# ==============================================================================
FROM devel as runtime

# Remove setup files and copy install directory
RUN rm -rf /autoware/*
COPY --from=prebuilt /autoware/install/ /autoware/install/

# Create entrypoint
RUN echo "source /autoware/install/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]

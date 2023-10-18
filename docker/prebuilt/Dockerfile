FROM ai_challenge:devel
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ROS_DISTRO="humble"

## Copy src/ files
COPY src/ /autoware/src/
WORKDIR /autoware

## Build and change permission for runtime data conversion
RUN source /opt/ros/"$ROS_DISTRO"/setup.bash \
  && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release --symlink-install \
  && find /autoware/install -type d -exec chmod 777 {} \;

## Create entrypoint
# hadolint ignore=DL3059
RUN echo "source /autoware/install/setup.bash" > /etc/bash.bashrc
CMD ["/bin/bash"]
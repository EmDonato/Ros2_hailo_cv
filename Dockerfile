ARG ROS_DISTRO=humble
ARG HAILORT_VERSION=4.4.0
ARG USERNAME=cv
ARG UID=1000
ARG GID=1000


# =============================================================================
# Base
# =============================================================================

FROM ros:${ROS_DISTRO}-ros-base-jammy AS base

ARG ROS_DISTRO
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-c"]

ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    ROS_DOMAIN_ID=0 \
    ROS_LOCALHOST_ONLY=0 \
    RCUTILS_LOGGING_USE_STDOUT=1 \
    RCUTILS_LOGGING_BUFFERED_STREAM=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
      ros-${ROS_DISTRO}-cv-bridge \
      libopencv-core4.5d \
      libopencv-imgproc4.5d \
      libopencv-imgcodecs4.5d \
      libturbojpeg0 \
    && rm -rf /var/lib/apt/lists/*


# =============================================================================
# Build HailoRT
# =============================================================================

FROM base AS hailort-builder

ARG HAILORT_VERSION
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      build-essential \
      cmake \
      pkg-config \
      python3-dev \
      python3-pip \
      python3-setuptools \
      python3-wheel \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# v4.x = Hailo-8 / Hailo-8L
RUN git clone \
      --depth 1 \
      --branch v${HAILORT_VERSION} \
      https://github.com/hailo-ai/hailort.git

# ---------------------------------------------------------------------------
# C++ HailoRT
# ---------------------------------------------------------------------------

RUN cmake \
      -S /tmp/hailort \
      -B /tmp/hailort/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/hailort/build -j$(nproc) \
    && cmake --install /tmp/hailort/build

# ---------------------------------------------------------------------------
# Python PyHailoRT -> hailo_platform
# ---------------------------------------------------------------------------

WORKDIR /tmp/hailort/hailort/libhailort/bindings/python/platform

RUN python3 -m pip wheel \
      --no-deps \
      . \
      --wheel-dir /tmp/hailo-wheels


# =============================================================================
# ROS workspace builder
# =============================================================================

FROM base AS ros-builder

ARG ROS_DISTRO
ARG DEBIAN_FRONTEND=noninteractive

# Hailo C++ headers/libs needed when compiling ROS packages
COPY --from=hailort-builder /usr/local/ /usr/local/

RUN ldconfig

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      pkg-config \
      libopencv-dev \
      libturbojpeg0-dev \
      python3-colcon-common-extensions \
      python3-rosdep \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ws

COPY src/ src/

RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build \
      --merge-install \
      --cmake-args \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF && \
    rm -rf build log


# =============================================================================
# Runtime
# =============================================================================

FROM base AS runtime

ARG ROS_DISTRO
ARG USERNAME
ARG UID
ARG GID

SHELL ["/bin/bash", "-c"]

ENV MODULE_SETUP=/ws/install/setup.bash

# HailoRT C/C++
COPY --from=hailort-builder /usr/local/ /usr/local/

# PyHailoRT wheel
COPY --from=hailort-builder /tmp/hailo-wheels/ /tmp/hailo-wheels/

RUN ldconfig && \
    python3 -m pip install /tmp/hailo-wheels/*.whl && \
    rm -rf /tmp/hailo-wheels

# User
RUN groupadd --gid ${GID} ${USERNAME} && \
    useradd \
      --uid ${UID} \
      --gid ${GID} \
      --create-home \
      --shell /bin/bash \
      ${USERNAME}

WORKDIR /ws

COPY --from=ros-builder /ws/install/ /ws/install/

COPY config/ /ws/config/
COPY docker-entrypoint.sh /ros_module_entrypoint.sh

RUN chmod 0755 /ros_module_entrypoint.sh && \
    mkdir -p /data && \
    chown -R ${USERNAME}:${USERNAME} /ws /data

USER ${USERNAME}

ENTRYPOINT ["/ros_module_entrypoint.sh"]

CMD ["ros2", "launch", "hailo_perception", "perception.launch.py"]
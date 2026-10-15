FROM auterion/app-base:v2
SHELL ["/bin/bash", "-c"]

ARG ROS_DISTRO=humble
ENV ROS_DISTRO=${ROS_DISTRO}


# Refresh expired Open Robotics ROS apt signing key (see
# https://discourse.openrobotics.org/t/new-gpg-keys-deployed-for-packages-ros-org/9454)
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
      -o /usr/share/keyrings/ros-archive-keyring.gpg

RUN apt-get update && apt-get upgrade -y

#Install fastrtps for discovery server
RUN apt-get install -y ros-${ROS_DISTRO}-rmw-fastrtps-cpp ros-${ROS_DISTRO}-rmw-fastrtps-shared-cpp


# #Install mavros and required geographic datasets
# RUN apt install -y ros-humble-mavros ros-humble-mavros-msgs ros-humble-mavros-extras
# RUN . /opt/ros/humble/setup.sh && ros2 run mavros install_geographiclib_datasets.sh

# MAVROS 2.16.0 from the ROS apt repo, pinned to exact builds for arm64 (the
# Skynode; the build stamps differ per architecture, so any other
# architecture fails here on purpose). Same versions as homebrew_docker.
#
# The ROS apt repo keeps only the newest build of each package. When a newer
# one is published, these versions disappear and this step FAILS instead of
# silently installing a different MAVROS. MAVROS renames topics between
# versions (2.15 moved everything under <namespace>/mavros/), so before
# changing the versions read MAVROS's CHANGELOG.rst and update all four
# together. apt-mark hold keeps later layers from changing them.
#
# Until app 0.4.0, MAVROS 2.14.0 was built from source here because of
# https://github.com/mavlink/mavros/issues/2293 (binaries missing from apt;
# closed 2026-09-27). A note here then said the apt packages were "still
# broken as of 2026-10-08" without saying how. 0.4.0 has NOT been tested on
# an Astro: test it on one before deploying (README section 4).
ARG LIBMAVCONN_VERSION=2.16.0-1jammy.20260927.155237
ARG MAVROS_VERSION=2.16.0-1jammy.20260927.163040
ARG MAVROS_EXTRAS_VERSION=2.16.0-1jammy.20260927.170609
ARG MAVROS_MSGS_VERSION=2.16.0-1jammy.20260927.155213
RUN if [[ "$(dpkg --print-architecture)" != "arm64" ]]; then \
        echo "ERROR: the MAVROS versions pinned here are arm64 builds; this is $(dpkg --print-architecture)." >&2; \
        exit 1; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-libmavconn=${LIBMAVCONN_VERSION} \
        ros-${ROS_DISTRO}-mavros=${MAVROS_VERSION} \
        ros-${ROS_DISTRO}-mavros-extras=${MAVROS_EXTRAS_VERSION} \
        ros-${ROS_DISTRO}-mavros-msgs=${MAVROS_MSGS_VERSION} && \
    apt-mark hold \
        ros-${ROS_DISTRO}-libmavconn ros-${ROS_DISTRO}-mavros \
        ros-${ROS_DISTRO}-mavros-extras ros-${ROS_DISTRO}-mavros-msgs

# Do this since running ros2 run mavros install_geographiclib_datasets.sh alone can give cryptic errors
RUN apt-get update && \
    apt-get install -y --no-install-recommends geographiclib-tools && \
    geographiclib-get-geoids egm96-5 && \
    GEOID_FILE="/usr/share/GeographicLib/geoids/egm96-5.pgm"; \
    if [[ ! -s "$GEOID_FILE" ]] || (( $(stat -c%s "$GEOID_FILE") < 1000000 )); then \
        echo "ERROR: $GEOID_FILE missing or too small after install." >&2; \
        exit 1; \
    fi; \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

#Configure ROS2 environment variables & discovery server
ENV ROS_LOCALHOST_ONLY=0
ENV ROS_DOMAIN_ID=0
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp
# Makes every node a plain discovery-server CLIENT
ENV ROS_DISCOVERY_SERVER=192.168.1.201:11811

RUN . /opt/ros/${ROS_DISTRO}/setup.sh && fastdds shm clean && ros2 daemon stop && ros2 daemon start
COPY astro.launch.xml /astro.launch.xml
# NAMESPACE comes from the app settings (settings.default.env)
CMD . /opt/ros/${ROS_DISTRO}/setup.sh && ros2 launch /astro.launch.xml namespace:=${NAMESPACE:?set NAMESPACE in the app settings}

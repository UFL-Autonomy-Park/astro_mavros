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

# TEMPORARY: ros-humble-mavros / mavros-extras / libmavconn are absent from
# the ROS 2 apt repo for jammy (both amd64 and arm64) as of 2026-09-16 -
# https://github.com/mavlink/mavros/issues/2293 - only mavros_msgs still
# publishes. Building all four from source at the last known-good tag
# (2.14.0) instead of apt-installing them. Once mavros/mavros-extras
# reappear in the apt index at a healthy version, revert this block back to
# the simple apt-get install ros-${ROS_DISTRO}-mavros ros-${ROS_DISTRO}-mavros-msgs
# ros-${ROS_DISTRO}-mavros-extras that used to live here.
RUN rosdep init && rosdep update 
RUN apt-get update && \
    apt-get install -y --no-install-recommends git python3-colcon-common-extensions && \
    mkdir -p /tmp/mavros_src/src && \
    git clone --branch 2.14.0 --depth 1 https://github.com/mavlink/mavros.git /tmp/mavros_src/src/mavros && \
    source /opt/ros/${ROS_DISTRO}/setup.bash && \
    rosdep install --from-paths /tmp/mavros_src/src --ignore-src -r -y

RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    cd /tmp/mavros_src && \
    colcon build --merge-install --install-base /opt/ros/${ROS_DISTRO}

# Do this since running ros2 run mavros install_geographiclib_datasets.sh alone can give cryptic errors
RUN apt-get update && \
    apt-get install -y --no-install-recommends geographiclib-tools && \
    geographiclib-get-geoids egm96-5 && \
    GEOID_FILE="/usr/share/GeographicLib/geoids/egm96-5.pgm"; \
    if [[ ! -s "$GEOID_FILE" ]] || (( $(stat -c%s "$GEOID_FILE") < 1000000 )); then \
        echo "ERROR: $GEOID_FILE missing or too small after install." >&2; \
        exit 1; \
    fi; \
    rm -rf /tmp/mavros_src && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

#Configure ROS2 environment variables & discovery server
ENV ROS_LOCALHOST_ONLY=0
ENV ROS_DOMAIN_ID=0
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp
ENV ROS_DISCOVERY_SERVER=192.168.1.201:11811
ENV FASTRTPS_DEFAULT_PROFILES_FILE=/super_client_config.xml

RUN . /opt/ros/${ROS_DISTRO}/setup.sh && fastdds shm clean && ros2 daemon stop && ros2 daemon start
CMD . /opt/ros/${ROS_DISTRO}/setup.sh && ros2 launch mavros px4.launch fcu_url:=tcp://127.0.0.1:5790 respawn_mavros:=true namespace:=$NAMESPACE

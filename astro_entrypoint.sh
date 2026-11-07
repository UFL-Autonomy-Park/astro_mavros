#!/bin/bash
# Starts MAVROS for the Astro. Before launching, restricts Fast DDS's UDP
# transport to the address this Skynode uses to reach the discovery server.
#
# Why: the container runs with network_mode: host, so Fast DDS would advertise
# every address on the Skynode (the Docker bridge 172.17.0.1, 10.41.10.1,
# 10.0.0.1, ...). A machine on the lab network cannot reach those. Reliable
# traffic back to the Astro (service requests, acknowledgements, the replay of
# latched topics such as mavros/state and global_position/gp_origin) then goes
# nowhere, while best-effort and volatile topics from the Astro still arrive.
# See README section 4.

if [[ -z "${NAMESPACE:-}" ]]; then
    echo "set NAMESPACE in the app settings" >&2
    exit 1
fi

# SSH for debugging. Port 2222 because of host networking (22 is AuterionOS's).
# A failure here must not stop MAVROS from starting.
/usr/sbin/sshd -p 2222 || echo "WARNING: sshd failed to start; no SSH access." >&2

source "/opt/ros/${ROS_DISTRO}/setup.bash"

PROFILE=/tmp/astro_fastdds.xml
SERVER="${ROS_DISCOVERY_SERVER%%;*}"
SERVER_HOST="${SERVER%:*}"
SERVER_PORT="${SERVER##*:}"

# Connecting a UDP socket sends nothing; it only makes the kernel pick the
# source address of the route to the server
local_ip=""
for _ in $(seq 1 60); do
    local_ip="$(python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((sys.argv[1], int(sys.argv[2])))
print(s.getsockname()[0])
' "${SERVER_HOST}" "${SERVER_PORT}" 2>/dev/null)" && [[ -n "${local_ip}" ]] && break
    local_ip=""
    sleep 1
done

if [[ -n "${local_ip}" ]]; then
    cat > "${PROFILE}" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<dds>
    <profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
        <transport_descriptors>
            <transport_descriptor>
                <transport_id>lan_udp</transport_id>
                <type>UDPv4</type>
                <interfaceWhiteList>
                    <address>${local_ip}</address>
                </interfaceWhiteList>
            </transport_descriptor>
            <transport_descriptor>
                <transport_id>shm</transport_id>
                <type>SHM</type>
            </transport_descriptor>
        </transport_descriptors>
        <participant profile_name="astro_lan_only" is_default_profile="true">
            <rtps>
                <useBuiltinTransports>false</useBuiltinTransports>
                <userTransports>
                    <transport_id>lan_udp</transport_id>
                    <transport_id>shm</transport_id>
                </userTransports>
            </rtps>
        </participant>
    </profiles>
</dds>
EOF
    export FASTRTPS_DEFAULT_PROFILES_FILE="${PROFILE}"
    echo "Fast DDS UDP restricted to ${local_ip} (route to ${SERVER_HOST})"
else
    echo "WARNING: no route to the discovery server ${SERVER_HOST}:${SERVER_PORT} after 60 s." >&2
    echo "WARNING: starting with every interface advertised; reliable traffic to the Astro will fail." >&2
fi

exec ros2 launch /astro.launch.xml "namespace:=${NAMESPACE}"

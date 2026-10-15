# astro_mavros

MAVROS for the Freefly Astro, packaged as an Auterion OS app. It runs
MAVROS 2.16.0 in a container on the Astro's Skynode, connects to the flight
controller over `tcp://127.0.0.1:5790`, and publishes every topic under a
per-vehicle namespace via the Fast DDS discovery server at `192.168.1.201:11811`.
MAVROS's topics and services are under `/<namespace>/mavros/` (e.g.
`/astro1/mavros/state`); app versions before 0.4.0 ran MAVROS 2.14.0, which
used `/<namespace>/state`.

This mirrors the MAVROS part of
[homebrew_docker](https://github.com/UFL-Autonomy-Park/homebrew_docker), minus
the ZED camera and NTRIP client.

## 1. Installation

Install the Auterion CLI (see also the
[Auterion CLI package](https://pypi.org/project/auterion-cli/)):

```bash
pip3 install auterion-cli
```

Make sure the Astro is connected over Wi-Fi or USB-C and run

```bash
auterion-cli device discover
```

The Astro should show up in the list with a
serial and IP address. Example:

```
$ auterion-cli device discover

Found devices
selected     serial   version    addresses
---------- --------- --------- -----------------
           131502818  vX.X.X     {'192.168.1.121'}

Note: Use 'device select' command to select a device to interact with
      Use 'device deselect' command to reset selection
```

To connect auterion-cli to the Astro, run

```bash
auterion-cli device select [serial]`
```
It should list whatever Astro is connected over USB. Example:

```
$ auterion-cli device select 131502818

Selected device with ID 131502818 on address 192.168.1.121
```

Clone and build the astro_mavros package from GitHub:

```bash
git clone https://github.com/UFL-Autonomy-Park/astro_mavros
cd astro_mavros
auterion-cli app build
```

Install the build on the selected Astro. The file name includes the
`app-version` from `auterion-app.yml`:

```bash
auterion-cli app install build/com.autonomy.astro_mavros-<version>.auterionos
```

You should see output indicating the install was successful:

```
Installing artifact build/com.autonomy.astro_mavros-<version>.auterionos
Looking for the update artifact
Check if your device is online...
API: v2.2
Uploading artifact: 246Mit [00:19, 12.9Mit/s]
Waiting for the device to complete the installation
The device has been updated successfully
```

## 2. Settings

Open the Astro's IP address in a web browser and go to the Apps section. For
Astro 1, the URL would be <http://192.168.1.121/apps>. Check the IP reservations document for IP addresses.

The astro_mavros app should now be listed. Click the gear icon and select
**Settings**.

> **Every Astro needs its own `NAMESPACE`.** It is empty by default and the
> app exits on startup until it is set. Pick the value from the table in §2.1.
> For a new Astro, add a row there first.

| Setting     | Description                                             |
|-------------|---------------------------------------------------------|
| `NAMESPACE` | Namespace for this Astro's MAVROS topics, e.g. `astro1` |

Then restart the app: click **Stop**, then **Start**, in the gear icon menu.

### 2.1 MAVLink system IDs

MAVROS links its internal router and plugins over the absolute topics
`/uas<tgt_system>/mavlink_source` and `/uas<tgt_system>/mavlink_sink`. The
namespace does not apply to them, and `tgt_system` must equal the flight
controller's `MAV_SYS_ID`. If two vehicles share an ID, they share these topics
through the discovery server, and one vehicle's MAVROS can report the other's
data under its own namespace.

**The Astros' `MAV_SYS_ID` cannot be changed.** Freefly reverts it to 1,
whether you change it from AMC or from the Herelink controller. So
`astro.launch.xml` fixes `tgt_system` at 1, and every Astro uses `/uas1`.

- **No other vehicle may use system ID 1** while an Astro is on the network.
  This was the original bug: the homebrews were on the PX4 default of 1 and
  showed Astro data under their own namespaces.
- **Astro to Astro:** with two Astros side by side, echoing each one's topics
  showed no bleed (tested 2026-10-08). Why is unknown: they do share `/uas1`.
  **Sending commands to one Astro while another is on has not been tested.**
  Before relying on it, do the check below.

Assigned IDs (keep this table up to date):

| Vehicle    | `NAMESPACE`  | `MAV_SYS_ID` / `tgt_system` |
|------------|--------------|-----------------------------|
| homebrew02 | `homebrew02` | 2 |
| homebrew03 | `homebrew03` | 3 |
| astro1     | `astro1`     | 1 (fixed by Freefly) |
| astro2     | `astro2`     | 1 (fixed by Freefly) |

New non-Astro vehicles need a unique ID other than 1 (the Astros) and 255
(ground control stations). New Astros get a new namespace and stay at 1.

The Astros have no gimbal. If one is added, `MNT_MAV_SYSID` (default 1)
already matches, since `MAV_SYS_ID` stays 1.

To list the shared topics from any machine on the network:

```bash
ros2 topic list | grep '^/uas'
ros2 topic info -v /uas1/mavlink_source   # one publisher per Astro that is on
```

#### Checking that commands don't cross between Astros

Do this with **the propellers removed** from both Astros and both of them on.
Arm one and confirm the other stays disarmed:

```bash
ros2 topic echo /astro2/mavros/state --field armed     # in one terminal
ros2 service call /astro1/mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: true}"
ros2 service call /astro1/mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: false}"
```

If astro2 arms too, or `/astro1/mavros/cmd/arming` reports success while astro1
stays disarmed, commands are crossing. In that case, don't run more than one
Astro with MAVROS at a time.

### 2.2 Other shared topics

MAVROS also uses `/tf`, `/tf_static`, `/diagnostics` and
`/move_base_simple/goal` under absolute names. `astro.launch.xml` remaps
them under the namespace, e.g. `/astro1/tf`, so vehicles don't hear each
other's transforms. `/rosout` and `/parameter_events` stay shared by design.

> [!WARNING]
> **With MAVROS 2.16 the remap no longer reaches `/move_base_simple/goal`.**
> MAVROS's plugin nodes ignore remaps since 2.15, and that topic belongs to
> the `guided_target` plugin, so it stays absolute and every Astro shares it.
> `/tf`, `/tf_static` and `/diagnostics` are still remapped (they belong to
> MAVROS's main and router nodes). Seen 2026-10-15 running this launch file
> with MAVROS 2.16.0 on a lab PC (not on an Astro). Nothing in the Autonomy
> Park stack uses `/move_base_simple/goal`.
To check for anything else outside the namespace:

```bash
ros2 topic list | grep -v '^/astro1/'
```

## 3. Verifying

You should now see namespaced Astro topics when you run `ros2 topic list`:

```
$ ros2 topic list
/astro1/diagnostics
/astro1/mavros/actuator_control
/astro1/mavros/adsb/send
/astro1/mavros/adsb/vehicle
/astro1/mavros/altitude
/astro1/mavros/battery
/astro1/mavros/camera/image_captured
/astro1/mavros/cam_imu_sync/cam_imu_stamp
...
```

The machine running `ros2` must also use the discovery server. MAVROS on the
Astro is a plain discovery-server CLIENT and only learns about topics it uses,
so to see the whole graph use a SUPER_CLIENT profile, e.g. the one in
homebrew_docker's `config/fastdds/super_client_config.xml`:

```bash
export FASTRTPS_DEFAULT_PROFILES_FILE=/path/to/super_client_config.xml
ros2 daemon stop
ros2 topic list
```

The first `ros2 topic list` after starting can miss topics while discovery
completes. Run it again.

Verify that messages are being published by echoing an active topic:

```bash
ros2 topic echo /astro1/mavros/battery
```

Example output:

```
header:
  stamp:
    sec: 1728658560
    nanosec: 149730930
  frame_id: ''
voltage: 22.83100128173828
temperature: 0.0
current: -0.3400000035762787
charge: .nan
capacity: .nan
design_capacity: .nan
percentage: 0.5799999833106995
power_supply_status: 2
power_supply_health: 0
power_supply_technology: 3
present: true
cell_voltage:
- 3.81000018119812
- 3.81000018119812
- 3.808000087738037
- 3.8030002117156982
- 3.8010001182556152
- 3.7990002632141113
cell_temperature: []
location: id0
serial_number: ''
```

## 4. Development notes

- **MAVROS 2.16.0 from apt, pinned to exact arm64 builds** (`Dockerfile`, same
  versions as homebrew_docker). Until 0.3.0, MAVROS 2.14.0 was built from
  source because the apt packages were missing
  ([mavlink/mavros#2293](https://github.com/mavlink/mavros/issues/2293),
  closed 2026-09-27); a note then said they were "still broken as of
  2026-10-08" without saying how. **0.4.0 has not been tested on an Astro.**
  Before deploying it, install it on one Astro and check, on the lab PC:
  `ros2 topic echo --once /astro1/mavros/state --field connected` prints
  `true`, the battery echo in [3](#3-verifying) shows data, and the arming
  test in [2.1](#21-mavlink-system-ids) passes (propellers removed).
- **Pinned versions can disappear.** The ROS apt repo keeps only the newest
  build, so once MAVROS publishes a newer one the Docker build fails at the
  MAVROS step. Then read MAVROS's changelog for topic changes and update the
  four versions in the `Dockerfile` together.
- **Bump `app-version` in `auterion-app.yml` for every release.** The build
  file name includes the version.
- **Discovery server address:** set by `ROS_DISCOVERY_SERVER` in the
  `Dockerfile`. There is no Fast DDS XML profile. With only this variable set,
  Fast DDS makes every node a plain CLIENT of that server.
- **Launch:** the container runs `astro.launch.xml`, which wraps MAVROS's
  `px4.launch` with the namespace, `tgt_system` (fixed at 1) and the remaps above.

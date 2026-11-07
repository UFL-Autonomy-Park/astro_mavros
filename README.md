# astro_mavros

MAVROS for the Freefly Astro, packaged as an Auterion OS app. It runs
MAVROS 2.16.0 in a container on the Astro's Skynode, connects to the flight
controller over `tcp://127.0.0.1:5790`, and publishes every topic under a
per-vehicle namespace via the Fast DDS discovery server at `192.168.1.201:11811`.
MAVROS's topics and services are under `/<namespace>/mavros/` (e.g.
`/astro1/mavros/state`); app versions before 0.4.0 ran MAVROS 2.14.0, which
used `/<namespace>/state`. Since 0.5.1 it loads only 12 MAVROS plugins instead
of about 60, which fixed stalled topics at startup (see
[4](#4-development-notes)).

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
  2026-10-08" without saying how. 0.4.0 was flown on astro1 on 2026-10-20.
- **Testing a new version.** Install it on one Astro and check, on the lab
  PC: `ros2 topic echo --once /astro1/mavros/state --field connected` prints
  `true`, the battery echo in [3](#3-verifying) shows data, and the arming
  test in [2.1](#21-mavlink-system-ids) passes (propellers removed).
- **Only 12 MAVROS plugins are loaded (0.5.1).** `minimal_pluginlists.yaml`
  (copied from homebrew_docker, minus `distance_sensor` and `px4flow`, which
  the Astros lack) denies everything not listed. `astro.launch.xml` includes
  MAVROS's `node.launch` directly with it, because `px4.launch` hardcodes
  `px4_pluginlists.yaml`, which denies only 5 plugins and so loads about 60.
  Since 2.15 each plugin is its own ROS node.

  **Why.** On 2026-11-06, astro1 (MAVROS 2.16.0, stock list) showed topics
  that arrived in bursts: `local_position/pose` and `imu/data` swung between
  about 5 and 40 Hz instead of 30 and 20 Hz, with stalls of 1-2 s followed by
  catch-up bursts, and `imu/data_raw` never published. The Skynode's CPU was
  80-88%, sometimes 100%. After every boot, with either MAVROS 2.14 or 2.16,
  `pose` and `imu/data` ran normally for 7-10 s, then dropped to 2-10 Hz for
  10-14 s, then delivered everything at once at 90-150 Hz (4 startups out of 4
  on the stock list). With the 12-plugin list, 4 of 4 startups were clean
  (two of them cold boots, one per Astro), `pose` held 30 Hz with no second
  below 25 Hz, and astro1's CPU fell to 26-50% (typically about 37%).

  **What it was not.** Not the network or the discovery server: the stall
  hit only the vehicle that was booting, and the other one, left running,
  stayed at 30 Hz. Not the MAVROS version: astro1 on 2.14.0 stalled the same
  way. Not the Freefly camera and payload apps: they were switched off.
  Not the receiving PC: header stamps were 3-25 ms behind arrival time.
  The messages leave MAVROS late and in a burst, so the data is delayed,
  not lost.

  **What is not established.** Which excluded plugin causes the load. My
  suspicion is MAVROS's startup requests (parameters, missions) over the slow
  router link, but that was not tested. To find out, add plugins back to
  `minimal_pluginlists.yaml` one at a time (`param` and `waypoint` first),
  rebuild, reboot the Astro, and watch for the stall.

  **What you lose.** Everything outside the list: no parameter, mission,
  RC override, geofence, gimbal, camera, ESC or HIL topics and services, among
  others. `ros2 topic list` shows about 100 fewer topics per Astro (54 instead of 158 on astro1) than
  with the stock list. Add the plugin to the allowlist if something needs it.

  **Checking for the stall.** After a boot, on the lab PC:
  `ros2 topic hz /astro1/mavros/local_position/pose` should settle at about
  30 Hz and stay there. A drop to under 10 Hz about 10 s after the first
  message means the problem is back. Averages over `ros2 topic hz`'s window
  hide the bursts, so look at the rate over time or the largest gap between
  messages, not the mean.
- **MAVROS timesync does not work reliably on the Astro.** MAVROS uses a
  TIMESYNC sample only if its round trip is under `max_rtt_sample` (default
  10 ms). Through Auterion's MAVLink router the round trip measured on astro1
  (2026-10-20, AuterionOS 3.7.30) was 12-341 ms, median about 70 ms, so
  MAVROS rejects every sample and logs `TM: RTT too high for timesync`. Then:
  - If it never converged since MAVROS started, the offset stays 0 and MAVROS
    stamps messages with the Skynode's time on arrival, not PX4's sample
    time. Ages computed from those stamps miss the PX4-to-MAVROS delay.
  - If it converged in a short window of low round trips after boot, the
    offset is frozen at that value and never corrected for drift.

  Check `estimated_offset_ns` in `/<namespace>/mavros/timesync_status`: 0
  means arrival-time stamps; a value that never changes means frozen. The
  round trip is inside Auterion's closed stack and cannot be tuned here.
  Commands take the same path, so the Astros are not suited to
  latency-sensitive offboard control (e.g. acceleration setpoints); use the
  homebrews for that.
- **Branch `api-v4-clock-check`** (app 0.5.0, not adopted): Apps API 4 and a
  clock check against the lab time server before MAVROS starts. MAVROS
  connected over `172.17.0.1:5790` on astro1, but API 4 gave nothing this app
  uses, so it was not merged into `main`.
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
  `node.launch` (the part of `px4.launch` that matters, with the same
  `px4_config.yaml`) with the namespace, `tgt_system` (fixed at 1), the
  12-plugin list and the remaps above.

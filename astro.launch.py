"""MAVROS for one Freefly Astro.

Replaces MAVROS's mavros_node, which hardcodes the MAVLink topic prefix
/uas<tgt_system>. tgt_system must equal the flight controller's MAV_SYS_ID,
which Freefly forces to 1 on every Astro, so with mavros_node every Astro
publishes and subscribes the same absolute topics /uas1/mavlink_source and
/uas1/mavlink_sink. Two Astros on one network then see each other's MAVLink:
one reports the other's data under its own namespace, and commands cross.

This file starts the same Router and UAS components as mavros_node (see
mavros's test_compose.launch.py) in a container, but with the prefix
/<namespace>/uas<tgt_system>, e.g. /astro1/uas1. See README section 2.1.
"""

import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode

MAVROS_SHARE = get_package_share_directory('mavros')


def global_parameters(path):
    """The /** section of a ROS parameter file, as a dict."""
    with open(path) as f:
        return (yaml.safe_load(f).get('/**') or {}).get('ros__parameters') or {}


def launch_setup(context):
    namespace = LaunchConfiguration('namespace').perform(context)
    tgt_system = int(LaunchConfiguration('tgt_system').perform(context))
    tgt_component = int(LaunchConfiguration('tgt_component').perform(context))
    fcu_url = LaunchConfiguration('fcu_url').perform(context)
    pluginlists_yaml = LaunchConfiguration('pluginlists_yaml').perform(context)
    config_yaml = LaunchConfiguration('config_yaml').perform(context)

    if not namespace:
        raise RuntimeError('namespace is required: it keeps this Astro\'s MAVLink topics apart from the other Astros\'')

    ns = '/' + namespace.strip('/')
    uas_url = f'{ns}/uas{tgt_system}'

    # Topics MAVROS uses under absolute names, which the namespace does not
    # apply to. Every vehicle would share them across the network, so they are
    # remapped under the vehicle's namespace. Since MAVROS 2.15 the plugin
    # nodes ignore remaps (README 2.2). A composed node does not inherit the
    # container's remaps, so they go on each node
    remappings = [
        ('/tf', f'{ns}/tf'),
        ('/tf_static', f'{ns}/tf_static'),
        ('/diagnostics', f'{ns}/diagnostics'),
        ('/move_base_simple/goal', f'{ns}/move_base_simple/goal'),
    ]

    router = ComposableNode(
        package='mavros',
        plugin='mavros::router::Router',
        name='mavros_router',
        namespace=ns,
        parameters=[{
            'fcu_urls': [fcu_url],
            'uas_urls': [uas_url],
            'fcu_protocol': 'v2.0',
        }],
        remappings=remappings,
        extra_arguments=[{'use_intra_process_comms': True}],
    )

    # Named "mavros" like mavros_node's UAS, so the topics stay under
    # /<namespace>/mavros/
    uas = ComposableNode(
        package='mavros',
        plugin='mavros::uas::UAS',
        name='mavros',
        namespace=ns,
        parameters=[
            # The UAS reads the plugin allowlist and denylist itself. A
            # composed node does not inherit the container's parameter files
            global_parameters(pluginlists_yaml),
            global_parameters(config_yaml),
            {
                'uas_url': uas_url,
                'fcu_protocol': 'v2.0',
                'target_system_id': tgt_system,
                'target_component_id': tgt_component,
            },
        ],
        remappings=remappings,
        extra_arguments=[{'use_intra_process_comms': True}],
    )

    # The per-plugin settings in the parameter files are keyed /**/<plugin>.
    # The plugins are separate nodes that the UAS creates, and they take
    # process-wide parameters, as under mavros_node, so the files also go to
    # the container.
    container = ComposableNodeContainer(
        name='mavros_node',
        namespace=ns,
        package='rclcpp_components',
        executable='component_container_mt',
        composable_node_descriptions=[router, uas],
        parameters=[pluginlists_yaml, config_yaml],
        remappings=remappings,
        respawn=True,
        output='screen',
    )
    return [container]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument('namespace'),
        # Must match the FCU's MAV_SYS_ID, which Freefly forces to 1 on every
        # Astro. The prefix is per namespace, so Astros can share it
        DeclareLaunchArgument('tgt_system', default_value='1'),
        DeclareLaunchArgument('tgt_component', default_value='1'),
        DeclareLaunchArgument('fcu_url', default_value='tcp://127.0.0.1:5790'),
        # A short allowlist, copied into the image by the Dockerfile.
        # px4.launch hardcodes px4_pluginlists.yaml (about 60 plugins)
        DeclareLaunchArgument('pluginlists_yaml', default_value='/minimal_pluginlists.yaml'),
        # Same as mavros's px4.launch
        DeclareLaunchArgument('config_yaml', default_value=os.path.join(MAVROS_SHARE, 'launch', 'px4_config.yaml')),
        OpaqueFunction(function=launch_setup),
    ])

// Describes the volume we want Nomad to create and manage.
name = "pocketbase-data-vol"
type = "host"

// Specifies that the volume should be placed on a node with the docker plugin.
plugin_id = "mkdir"

// Defines the required capacity. Nomad will ensure the underlying
// host has enough space.
capacity_min = "500MB"
capacity_max = "1GB"

locals {
  # Flat per-server maps for control plane and workers
  control_plane_servers_map = merge([
    for np_index in range(length(local.control_plane_nodepools)) : {
      for cp_index in range(local.control_plane_nodepools[np_index].count) :
      "${var.cluster_name}-${local.control_plane_nodepools[np_index].name}-${cp_index + 1}" => {
        name        = local.control_plane_nodepools[np_index].name,
        index       = cp_index + 1,
        server_type = local.control_plane_nodepools[np_index].server_type,
        zone        = local.control_plane_nodepools[np_index].zone,
        labels      = local.control_plane_nodepools[np_index].labels,
      }
    }
  ]...)

  worker_servers_map = merge([
    for np_index in range(length(local.worker_nodepools)) : {
      for wkr_index in range(local.worker_nodepools[np_index].count) :
      "${var.cluster_name}-${local.worker_nodepools[np_index].name}-${wkr_index + 1}" => {
        name            = local.worker_nodepools[np_index].name,
        index           = wkr_index + 1,
        server_type     = local.worker_nodepools[np_index].server_type,
        zone            = local.worker_nodepools[np_index].zone,
        labels          = local.worker_nodepools[np_index].labels,
        placement_group = local.worker_nodepools[np_index].placement_group,
      }
    }
  ]...)
}

# ─── Public IPs (separate resources on Scaleway) ────────────────────────────

resource "scaleway_instance_ip" "control_plane" {
  for_each = { for k, v in local.control_plane_servers_map : k => v if var.talos_public_ipv4_enabled }

  tags = [var.cluster_name, "role=control-plane", "node=${each.key}"]
}

resource "scaleway_instance_ip" "worker" {
  for_each = { for k, v in local.worker_servers_map : k => v if var.talos_public_ipv4_enabled }

  tags = [var.cluster_name, "role=worker", "node=${each.key}"]
}

# ─── Control Plane Servers ───────────────────────────────────────────────────

resource "scaleway_instance_server" "control_plane" {
  for_each = local.control_plane_servers_map

  name  = each.key
  type  = each.value.server_type
  image = startswith(upper(each.value.server_type), "COPARM1") ? local.talos_image_arm64_id : local.talos_image_amd64_id
  zone  = each.value.zone

  ip_id = var.talos_public_ipv4_enabled ? scaleway_instance_ip.control_plane[each.key].id : null
  # Note: IPv6 on Scaleway is enabled at the instance type level, not per-server

  security_group_id  = local.security_group_id
  placement_group_id = scaleway_instance_placement_group.control_plane.id

  additional_volume_ids = [scaleway_instance_volume.control_plane[each.key].id]

  tags = [var.cluster_name, "role=control-plane", "nodepool=${each.value.name}"]

  lifecycle {
    ignore_changes = [image, user_data, security_group_id]
  }
}

resource "scaleway_instance_volume" "control_plane" {
  for_each = local.control_plane_servers_map

  name       = "${each.key}-data"
  type       = "l_ssd"
  size_in_gb = 25
  zone       = each.value.zone

  tags = [var.cluster_name, "role=control-plane"]
}

resource "scaleway_instance_private_nic" "control_plane" {
  for_each = local.control_plane_servers_map

  server_id          = scaleway_instance_server.control_plane[each.key].id
  private_network_id = scaleway_vpc_private_network.cluster.id
}

data "scaleway_ipam_ip" "control_plane" {
  for_each = local.control_plane_servers_map

  resource {
    id   = scaleway_instance_private_nic.control_plane[each.key].id
    type = "instance_private_nic"
  }
  type = "ipv4"
}

# ─── Worker Servers ──────────────────────────────────────────────────────────

resource "scaleway_instance_server" "worker" {
  for_each = local.worker_servers_map

  name  = each.key
  type  = each.value.server_type
  image = startswith(upper(each.value.server_type), "COPARM1") ? local.talos_image_arm64_id : local.talos_image_amd64_id
  zone  = each.value.zone

  ip_id = var.talos_public_ipv4_enabled ? scaleway_instance_ip.worker[each.key].id : null
  # Note: IPv6 on Scaleway is enabled at the instance type level, not per-server

  security_group_id = local.security_group_id
  placement_group_id = (
    each.value.placement_group ?
    scaleway_instance_placement_group.worker["${var.cluster_name}-${each.value.name}-pg-${ceil(each.value.index / 20.0)}"].id :
    null
  )

  additional_volume_ids = [scaleway_instance_volume.worker[each.key].id]

  tags = [var.cluster_name, "role=worker", "nodepool=${each.value.name}"]

  lifecycle {
    ignore_changes = [image, user_data, security_group_id]
  }
}

resource "scaleway_instance_volume" "worker" {
  for_each = local.worker_servers_map

  name       = "${each.key}-data"
  type       = "l_ssd"
  size_in_gb = 25
  zone       = each.value.zone

  tags = [var.cluster_name, "role=worker"]
}

resource "scaleway_instance_private_nic" "worker" {
  for_each = local.worker_servers_map

  server_id          = scaleway_instance_server.worker[each.key].id
  private_network_id = scaleway_vpc_private_network.cluster.id
}

data "scaleway_ipam_ip" "worker" {
  for_each = local.worker_servers_map

  resource {
    id   = scaleway_instance_private_nic.worker[each.key].id
    type = "instance_private_nic"
  }
  type = "ipv4"
}

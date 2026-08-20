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

  # The Talos ephemeral partition lives on either a legacy compute volume
  # (l_ssd via scaleway_instance_volume) or an SBS volume (sbs_volume via
  # scaleway_block_volume). scaleway_instance_volume.type does not accept
  # sbs_volume, so the resource has to be picked at plan time.
  ephemeral_use_sbs = var.talos_ephemeral_volume_type == "sbs_volume"
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

# ─── SBS Root Volumes (one per server, from the zonal block snapshot) ───────
#
# Only created on the SBS path. Sized/IOPS'd here rather than inside the
# server's root_volume block — see the comment there.
resource "scaleway_block_volume" "control_plane_root" {
  for_each = local.ephemeral_use_sbs ? local.control_plane_servers_map : {}

  name        = "${each.key}-root"
  zone        = each.value.zone
  snapshot_id = local.sbs_root_snapshots["${startswith(upper(each.value.server_type), "COPARM1") ? "arm64" : "amd64"}/${each.value.zone}"]
  iops        = var.talos_root_volume_iops
  size_in_gb  = var.talos_root_volume_size_gb

  tags = [var.cluster_name, "role=control-plane", "node=${each.key}"]

  lifecycle {
    precondition {
      condition     = contains(keys(local.sbs_root_snapshots), "${startswith(upper(each.value.server_type), "COPARM1") ? "arm64" : "amd64"}/${each.value.zone}")
      error_message = "No SBS root snapshot for ${each.key}: no image built for its architecture in zone ${each.value.zone}. Without this guard snapshot_id would be null and Scaleway would create a BLANK volume that boots nothing, with no error."
    }
  }
}

resource "scaleway_instance_server" "control_plane" {
  for_each = local.control_plane_servers_map

  name = each.key
  type = each.value.server_type
  # `image` and `root_volume.0.volume_id` are ExactlyOneOf in the provider, so
  # the SBS path MUST omit the image and boot from the pre-created root volume.
  image = local.ephemeral_use_sbs ? null : (
    startswith(upper(each.value.server_type), "COPARM1") ? local.talos_image_arm64_id : local.talos_image_amd64_id
  )
  zone = each.value.zone

  ip_id = var.talos_public_ipv4_enabled ? scaleway_instance_ip.control_plane[each.key].id : null
  # Note: IPv6 on Scaleway is enabled at the instance type level, not per-server

  security_group_id  = local.security_group_id
  placement_group_id = scaleway_instance_placement_group.control_plane.id

  # PRO2-* / PROD2-* / ENT1-* and other non-DEV1 instance families reject ANY
  # lssd attachment, including the implicit root volume. Use an SBS root volume
  # whenever the ephemeral path is also SBS — that's a clean proxy for "this
  # instance family does not support lssd at all".
  dynamic "root_volume" {
    for_each = local.ephemeral_use_sbs ? [1] : []
    content {
      volume_id   = scaleway_block_volume.control_plane_root[each.key].id
      volume_type = "sbs_volume"
      # delete_on_termination defaults to TRUE, which would let Scaleway
      # delete a Terraform-managed volume on instance termination: destroy
      # then 404s, and a replacement points the new server at a deleted
      # UUID and fails mid-apply. Terraform owns this volume's lifecycle.
      delete_on_termination = false
      # NO size_in_gb / sbs_iops here. With volume_id set, the provider
      # sends Size only when ID == "" (instancehelpers/block.go), so they
      # are ignored at create and then, being Optional+Computed, produce a
      # permanent diff that turns into a resize. They belong on the
      # scaleway_block_volume resource instead.
    }
  }

  additional_volume_ids = [
    local.ephemeral_use_sbs ?
    scaleway_block_volume.control_plane[each.key].id :
    scaleway_instance_volume.control_plane[each.key].id
  ]

  tags = [var.cluster_name, "role=control-plane", "nodepool=${each.value.name}"]

  lifecycle {
    # additional_volume_ids: ignored because Scaleway CSI dynamically attaches
    # PVC-backed volumes to the instance, which would otherwise show as drift
    # and cause Terraform to detach live workload storage.
    ignore_changes = [image, user_data, security_group_id, additional_volume_ids]
  }
}

resource "scaleway_instance_volume" "control_plane" {
  for_each = local.ephemeral_use_sbs ? {} : local.control_plane_servers_map

  name       = "${each.key}-data"
  type       = var.talos_ephemeral_volume_type
  size_in_gb = var.talos_ephemeral_volume_size_gb
  zone       = each.value.zone

  tags = [var.cluster_name, "role=control-plane"]
}

resource "scaleway_block_volume" "control_plane" {
  for_each = local.ephemeral_use_sbs ? local.control_plane_servers_map : {}

  name       = "${each.key}-data"
  iops       = var.talos_ephemeral_volume_iops
  size_in_gb = var.talos_ephemeral_volume_size_gb
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

# ─── SBS Root Volumes (one per server, from the zonal block snapshot) ───────
#
# Only created on the SBS path. Sized/IOPS'd here rather than inside the
# server's root_volume block — see the comment there.
resource "scaleway_block_volume" "worker_root" {
  for_each = local.ephemeral_use_sbs ? local.worker_servers_map : {}

  name        = "${each.key}-root"
  zone        = each.value.zone
  snapshot_id = local.sbs_root_snapshots["${startswith(upper(each.value.server_type), "COPARM1") ? "arm64" : "amd64"}/${each.value.zone}"]
  iops        = var.talos_root_volume_iops
  size_in_gb  = var.talos_root_volume_size_gb

  tags = [var.cluster_name, "role=worker", "node=${each.key}"]

  lifecycle {
    precondition {
      condition     = contains(keys(local.sbs_root_snapshots), "${startswith(upper(each.value.server_type), "COPARM1") ? "arm64" : "amd64"}/${each.value.zone}")
      error_message = "No SBS root snapshot for ${each.key}: no image built for its architecture in zone ${each.value.zone}. Without this guard snapshot_id would be null and Scaleway would create a BLANK volume that boots nothing, with no error."
    }
  }
}

resource "scaleway_instance_server" "worker" {
  for_each = local.worker_servers_map

  name = each.key
  type = each.value.server_type
  # `image` and `root_volume.0.volume_id` are ExactlyOneOf in the provider, so
  # the SBS path MUST omit the image and boot from the pre-created root volume.
  image = local.ephemeral_use_sbs ? null : (
    startswith(upper(each.value.server_type), "COPARM1") ? local.talos_image_arm64_id : local.talos_image_amd64_id
  )
  zone = each.value.zone

  ip_id = var.talos_public_ipv4_enabled ? scaleway_instance_ip.worker[each.key].id : null
  # Note: IPv6 on Scaleway is enabled at the instance type level, not per-server

  security_group_id = local.security_group_id
  placement_group_id = (
    each.value.placement_group ?
    scaleway_instance_placement_group.worker["${var.cluster_name}-${each.value.name}-pg-${ceil(each.value.index / 20.0)}"].id :
    null
  )

  # See control_plane.root_volume comment for the rationale.
  dynamic "root_volume" {
    for_each = local.ephemeral_use_sbs ? [1] : []
    content {
      volume_id   = scaleway_block_volume.worker_root[each.key].id
      volume_type = "sbs_volume"
      # delete_on_termination defaults to TRUE, which would let Scaleway
      # delete a Terraform-managed volume on instance termination: destroy
      # then 404s, and a replacement points the new server at a deleted
      # UUID and fails mid-apply. Terraform owns this volume's lifecycle.
      delete_on_termination = false
      # NO size_in_gb / sbs_iops here. With volume_id set, the provider
      # sends Size only when ID == "" (instancehelpers/block.go), so they
      # are ignored at create and then, being Optional+Computed, produce a
      # permanent diff that turns into a resize. They belong on the
      # scaleway_block_volume resource instead.
    }
  }

  additional_volume_ids = [
    local.ephemeral_use_sbs ?
    scaleway_block_volume.worker[each.key].id :
    scaleway_instance_volume.worker[each.key].id
  ]

  tags = [var.cluster_name, "role=worker", "nodepool=${each.value.name}"]

  lifecycle {
    # additional_volume_ids: ignored because Scaleway CSI dynamically attaches
    # PVC-backed volumes to the instance, which would otherwise show as drift
    # and cause Terraform to detach live workload storage.
    ignore_changes = [image, user_data, security_group_id, additional_volume_ids]
  }
}

resource "scaleway_instance_volume" "worker" {
  for_each = local.ephemeral_use_sbs ? {} : local.worker_servers_map

  name       = "${each.key}-data"
  type       = var.talos_ephemeral_volume_type
  size_in_gb = var.talos_ephemeral_volume_size_gb
  zone       = each.value.zone

  tags = [var.cluster_name, "role=worker"]
}

resource "scaleway_block_volume" "worker" {
  for_each = local.ephemeral_use_sbs ? local.worker_servers_map : {}

  name       = "${each.key}-data"
  iops       = var.talos_ephemeral_volume_iops
  size_in_gb = var.talos_ephemeral_volume_size_gb
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

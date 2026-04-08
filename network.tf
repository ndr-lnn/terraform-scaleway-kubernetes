locals {
  network_public_ipv4_enabled = var.talos_public_ipv4_enabled
  network_public_ipv6_enabled = var.talos_public_ipv6_enabled && var.talos_ipv6_enabled

  vpc_id = length(data.scaleway_vpc.this) > 0 ? data.scaleway_vpc.this[0].id : scaleway_vpc.this[0].id

  # Network ranges
  # Note: Scaleway VPC is a regional container without an inherent CIDR.
  # The network_ipv4_cidr is always taken from var.network_ipv4_cidr regardless of whether
  # an existing VPC is referenced or a new one is created.
  network_ipv4_cidr                = var.network_ipv4_cidr
  network_node_ipv4_cidr           = coalesce(var.network_node_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 2))
  network_service_ipv4_cidr        = coalesce(var.network_service_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 3))
  network_pod_ipv4_cidr            = coalesce(var.network_pod_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 1, 1))
  network_native_routing_ipv4_cidr = coalesce(var.network_native_routing_ipv4_cidr, local.network_ipv4_cidr)

  network_node_ipv4_cidr_skip_first_subnet = cidrhost(local.network_ipv4_cidr, 0) == cidrhost(local.network_node_ipv4_cidr, 0)
  network_ipv4_gateway                     = cidrhost(local.network_ipv4_cidr, 1)

  # Subnet mask sizes
  network_pod_ipv4_subnet_mask_size = 24
  network_node_ipv4_subnet_mask_size = coalesce(
    var.network_node_ipv4_subnet_mask_size,
    32 - (local.network_pod_ipv4_subnet_mask_size - split("/", local.network_pod_ipv4_cidr)[1])
  )

  # Lists for control plane nodes
  control_plane_public_ipv4_list  = compact(distinct([for ip in scaleway_instance_ip.control_plane : ip.address]))
  control_plane_public_ipv6_list  = [] # Scaleway instance_server has no ipv6_address attribute
  control_plane_private_ipv4_list = compact(distinct([for ip in data.scaleway_ipam_ip.control_plane : ip.address]))

  # Control plane VIP (LB-based only -- no floating IP on Scaleway for instances)
  control_plane_private_vip_ipv4 = cidrhost(scaleway_vpc_private_network.control_plane.ipv4_subnet[0].subnet, -2)

  # Lists for worker nodes
  worker_public_ipv4_list  = compact(distinct([for ip in scaleway_instance_ip.worker : ip.address]))
  worker_public_ipv6_list  = [] # Scaleway instance_server has no ipv6_address attribute
  worker_private_ipv4_list = compact(distinct([for ip in data.scaleway_ipam_ip.worker : ip.address]))
}

data "scaleway_vpc" "this" {
  count = var.scaleway_vpc != null || var.scaleway_vpc_id != null ? 1 : 0

  vpc_id = var.scaleway_vpc != null ? var.scaleway_vpc.id : var.scaleway_vpc_id
}

resource "scaleway_vpc" "this" {
  count = length(data.scaleway_vpc.this) > 0 ? 0 : 1

  name = var.cluster_name
  tags = ["cluster:${var.cluster_name}"]
}

resource "scaleway_vpc_private_network" "control_plane" {
  name   = "${var.cluster_name}-control-plane"
  vpc_id = local.vpc_id
  tags   = ["cluster:${var.cluster_name}", "role:control-plane"]

  ipv4_subnet {
    subnet = cidrsubnet(
      local.network_node_ipv4_cidr,
      local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
      0 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)
    )
  }
}

resource "scaleway_vpc_private_network" "load_balancer" {
  name   = "${var.cluster_name}-load-balancer"
  vpc_id = local.vpc_id
  tags   = ["cluster:${var.cluster_name}", "role:load-balancer"]

  ipv4_subnet {
    subnet = cidrsubnet(
      local.network_node_ipv4_cidr,
      local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
      1 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)
    )
  }
}

resource "scaleway_vpc_private_network" "worker" {
  for_each = { for np in local.worker_nodepools : np.name => np }

  name   = "${var.cluster_name}-${each.key}"
  vpc_id = local.vpc_id
  tags   = ["cluster:${var.cluster_name}", "role:worker", "pool:${each.key}"]

  ipv4_subnet {
    subnet = cidrsubnet(
      local.network_node_ipv4_cidr,
      local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
      2 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0) + index(local.worker_nodepools, each.value)
    )
  }
}

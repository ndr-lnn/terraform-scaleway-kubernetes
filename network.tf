locals {
  network_public_ipv4_enabled = var.talos_public_ipv4_enabled
  network_public_ipv6_enabled = var.talos_public_ipv6_enabled && var.talos_ipv6_enabled

  vpc_id = length(data.scaleway_vpc.this) > 0 ? data.scaleway_vpc.this[0].id : scaleway_vpc.this[0].id

  # Network ranges
  # Note: Scaleway VPC is a regional container. Private networks within a VPC
  # are isolated L2 segments. All nodes MUST be on the same private network
  # for inter-node communication (unlike Hetzner where subnets share L2).
  network_ipv4_cidr                = var.network_ipv4_cidr
  network_node_ipv4_cidr           = coalesce(var.network_node_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 2))
  network_service_ipv4_cidr        = coalesce(var.network_service_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 3))
  network_pod_ipv4_cidr            = coalesce(var.network_pod_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 1, 1))
  network_native_routing_ipv4_cidr = coalesce(var.network_native_routing_ipv4_cidr, local.network_ipv4_cidr)

  network_ipv4_gateway = cidrhost(local.network_ipv4_cidr, 1)

  # Lists for control plane nodes
  control_plane_public_ipv4_list  = compact(distinct([for ip in scaleway_instance_ip.control_plane : ip.address]))
  control_plane_public_ipv6_list  = [] # Scaleway instance_server has no ipv6_address attribute
  control_plane_private_ipv4_list = compact(distinct([for ip in data.scaleway_ipam_ip.control_plane : ip.address]))

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

# Single private network for ALL nodes (control plane, workers, LBs).
# Scaleway private networks are isolated L2 segments -- separate networks
# cannot communicate with each other. All cluster components must share one.
resource "scaleway_vpc_private_network" "cluster" {
  name   = "${var.cluster_name}-cluster"
  vpc_id = local.vpc_id
  tags   = ["cluster:${var.cluster_name}"]

  ipv4_subnet {
    # Scaleway private network subnets must be between /20 and /29.
    # We use the first /24 from the node CIDR range.
    subnet = cidrsubnet(local.network_node_ipv4_cidr, 24 - split("/", local.network_node_ipv4_cidr)[1], 0)
  }
}

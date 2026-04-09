# Public Gateway resources for private cluster mode.
# All resources in this file are gated on var.cluster_access == "private".
# The gateway provides outbound internet access (NAT/masquerade) for nodes
# that do not have public IP addresses.

resource "scaleway_vpc_public_gateway_ip" "this" {
  count = var.cluster_access == "private" ? 1 : 0

  tags = ["cluster:${var.cluster_name}"]
}

resource "scaleway_vpc_public_gateway" "this" {
  count = var.cluster_access == "private" ? 1 : 0

  name            = var.cluster_name
  type            = "VPC-GW-S"
  ip_id           = scaleway_vpc_public_gateway_ip.this[0].id
  bastion_enabled = false
  tags            = ["cluster:${var.cluster_name}"]
}

resource "scaleway_vpc_gateway_network" "cluster" {
  count = var.cluster_access == "private" ? 1 : 0

  gateway_id         = scaleway_vpc_public_gateway.this[0].id
  private_network_id = scaleway_vpc_private_network.cluster.id
  enable_masquerade  = true

  depends_on = [
    scaleway_vpc_private_network.cluster,
  ]
}

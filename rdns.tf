# Reverse DNS for Scaleway instances and load balancers.
#
# Scaleway rDNS model:
#   - Instance public IPv4: managed via `scaleway_instance_ip_reverse_dns` (per `scaleway_instance_ip` resource).
#   - Instance public IPv6: Scaleway does not provide a dedicated rDNS resource for the inline IPv6
#     address on `scaleway_instance_server`. IPv6 rDNS is therefore NOT supported on Scaleway and is
#     silently skipped. This is a known limitation.
#   - Load balancer IPs: rDNS for CCM-managed LBs is handled via LB annotations, not Terraform.

locals {
  rdns_cluster_domain_pattern = "/{{\\s*cluster-domain\\s*}}/"
  rdns_cluster_name_pattern   = "/{{\\s*cluster-name\\s*}}/"
  rdns_hostname_pattern       = "/{{\\s*hostname\\s*}}/"
  rdns_id_pattern             = "/{{\\s*id\\s*}}/"
  rdns_ip_labels_pattern      = "/{{\\s*ip-labels\\s*}}/"
  rdns_ip_type_pattern        = "/{{\\s*ip-type\\s*}}/"
  rdns_pool_pattern           = "/{{\\s*pool\\s*}}/"
  rdns_role_pattern           = "/{{\\s*role\\s*}}/"

  cluster_rdns_ipv4 = var.cluster_rdns_ipv4 != null ? var.cluster_rdns_ipv4 : var.cluster_rdns
  cluster_rdns_ipv6 = var.cluster_rdns_ipv6 != null ? var.cluster_rdns_ipv6 : var.cluster_rdns

  # Helper: apply all template substitutions to a raw rDNS pattern.
  # Used by the computed_rdns_for_* locals below.
  # Terraform does not allow function definitions, so this logic is repeated inline
  # in each computed_rdns_for_* local using the same nested replace() chain.

  # ─── Control plane IPv4 rDNS ────────────────────────────────────────────────
  # Keyed by server name (same key as scaleway_instance_ip.control_plane).
  # Only produced when the nodepool has an rdns_ipv4 template configured.
  computed_rdns_for_control_plane = {
    for key, ip in scaleway_instance_ip.control_plane :
    key => replace(replace(replace(replace(replace(replace(replace(replace(
      local.control_plane_nodepools_map[local.control_plane_servers_map[key].name].rdns_ipv4,
      local.rdns_cluster_domain_pattern, var.cluster_domain),
      local.rdns_cluster_name_pattern, var.cluster_name),
      local.rdns_hostname_pattern, scaleway_instance_server.control_plane[key].name),
      local.rdns_id_pattern, scaleway_instance_server.control_plane[key].id),
      local.rdns_ip_labels_pattern, join(".", reverse(split(".", ip.address)))),
      local.rdns_ip_type_pattern, "ipv4"),
      local.rdns_pool_pattern, local.control_plane_servers_map[key].name),
    local.rdns_role_pattern, "control-plane")
    if local.control_plane_nodepools_map[local.control_plane_servers_map[key].name].rdns_ipv4 != null
  }

  # ─── Worker IPv4 rDNS ───────────────────────────────────────────────────────
  computed_rdns_for_worker = {
    for key, ip in scaleway_instance_ip.worker :
    key => replace(replace(replace(replace(replace(replace(replace(replace(
      local.worker_nodepools_map[local.worker_servers_map[key].name].rdns_ipv4,
      local.rdns_cluster_domain_pattern, var.cluster_domain),
      local.rdns_cluster_name_pattern, var.cluster_name),
      local.rdns_hostname_pattern, scaleway_instance_server.worker[key].name),
      local.rdns_id_pattern, scaleway_instance_server.worker[key].id),
      local.rdns_ip_labels_pattern, join(".", reverse(split(".", ip.address)))),
      local.rdns_ip_type_pattern, "ipv4"),
      local.rdns_pool_pattern, local.worker_servers_map[key].name),
    local.rdns_role_pattern, "worker")
    if local.worker_nodepools_map[local.worker_servers_map[key].name].rdns_ipv4 != null
  }

}

# ─── Control Plane Instance IPv4 rDNS ───────────────────────────────────────

resource "scaleway_instance_ip_reverse_dns" "control_plane" {
  for_each = {
    for key, ip in scaleway_instance_ip.control_plane :
    key => ip
    if local.control_plane_nodepools_map[local.control_plane_servers_map[key].name].rdns_ipv4 != null
  }

  ip_id   = each.value.id
  reverse = local.computed_rdns_for_control_plane[each.key]
}

# ─── Worker Instance IPv4 rDNS ──────────────────────────────────────────────

resource "scaleway_instance_ip_reverse_dns" "worker" {
  for_each = {
    for key, ip in scaleway_instance_ip.worker :
    key => ip
    if local.worker_nodepools_map[local.worker_servers_map[key].name].rdns_ipv4 != null
  }

  ip_id   = each.value.id
  reverse = local.computed_rdns_for_worker[each.key]
}

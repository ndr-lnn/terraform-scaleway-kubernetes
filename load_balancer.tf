# Kubernetes API Load Balancer
locals {
  # LB private IP is known via the pre-reserved IPAM IP resource.
  kube_api_load_balancer_private_ipv4 = var.kube_api_load_balancer_enabled ? scaleway_ipam_ip.kube_api_lb[0].address : null
  kube_api_load_balancer_public_ipv4  = var.kube_api_load_balancer_enabled ? scaleway_lb_ip.kube_api[0].ip_address : null
  kube_api_load_balancer_public_ipv6  = null # Scaleway LB IPs are IPv4-only
  kube_api_load_balancer_name         = "${var.cluster_name}-kube-api"

  kube_api_load_balancer_public_network_enabled = coalesce(
    var.kube_api_load_balancer_public_network_enabled,
    var.cluster_access == "public"
  )
}

resource "scaleway_lb_ip" "kube_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0
  zone  = var.scaleway_zone
}

resource "scaleway_ipam_ip" "kube_api_lb" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }

  tags = [var.cluster_name, "role=kube-api-lb"]
}

resource "scaleway_lb" "kube_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  name   = local.kube_api_load_balancer_name
  ip_ids = [scaleway_lb_ip.kube_api[0].id]
  zone   = var.scaleway_zone
  type   = var.kube_api_load_balancer_type
  tags   = [var.cluster_name, "role=kube-api"]

  external_private_networks = true
}

resource "scaleway_lb_private_network" "kube_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id              = scaleway_lb.kube_api[0].id
  private_network_id = scaleway_vpc_private_network.cluster.id
  zone               = var.scaleway_zone
  ipam_ip_ids        = [scaleway_ipam_ip.kube_api_lb[0].id]
}

resource "scaleway_lb_backend" "kube_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id            = scaleway_lb.kube_api[0].id
  name             = "kube-api"
  forward_protocol = "tcp"
  forward_port     = local.kube_api_port
  server_ips       = local.control_plane_private_ipv4_list

  health_check_tcp {}
  health_check_delay       = "${var.kube_api_load_balancer_health_check_interval}s"
  health_check_timeout     = "${var.kube_api_load_balancer_health_check_timeout}s"
  health_check_max_retries = var.kube_api_load_balancer_health_check_retries

  depends_on = [scaleway_lb_private_network.kube_api]
}

# Trustd backend/frontend (port 50001) - required for worker certificate signing
# Workers connect to trustd via the LB since there's no VIP on Scaleway
resource "scaleway_lb_backend" "trustd" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id            = scaleway_lb.kube_api[0].id
  name             = "trustd"
  forward_protocol = "tcp"
  forward_port     = 50001
  server_ips       = local.control_plane_private_ipv4_list

  health_check_tcp {}
  health_check_delay       = "${var.kube_api_load_balancer_health_check_interval}s"
  health_check_timeout     = "${var.kube_api_load_balancer_health_check_timeout}s"
  health_check_max_retries = var.kube_api_load_balancer_health_check_retries

  depends_on = [scaleway_lb_private_network.kube_api]
}

resource "scaleway_lb_frontend" "trustd" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id        = scaleway_lb.kube_api[0].id
  name         = "trustd"
  backend_id   = scaleway_lb_backend.trustd[0].id
  inbound_port = 50001
}

# Talos API backend/frontend (port 50000) - for talosctl access via LB
resource "scaleway_lb_backend" "talos_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id            = scaleway_lb.kube_api[0].id
  name             = "talos-api"
  forward_protocol = "tcp"
  forward_port     = 50000
  server_ips       = local.control_plane_private_ipv4_list

  health_check_tcp {}
  health_check_delay       = "${var.kube_api_load_balancer_health_check_interval}s"
  health_check_timeout     = "${var.kube_api_load_balancer_health_check_timeout}s"
  health_check_max_retries = var.kube_api_load_balancer_health_check_retries

  depends_on = [scaleway_lb_private_network.kube_api]
}

resource "scaleway_lb_frontend" "talos_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id        = scaleway_lb.kube_api[0].id
  name         = "talos-api"
  backend_id   = scaleway_lb_backend.talos_api[0].id
  inbound_port = 50000
}

resource "scaleway_lb_frontend" "kube_api" {
  count = var.kube_api_load_balancer_enabled ? 1 : 0

  lb_id        = scaleway_lb.kube_api[0].id
  backend_id   = scaleway_lb_backend.kube_api[0].id
  name         = "kube-api"
  inbound_port = local.kube_api_port
}

# Ingress Load Balancer Pools
# Optional Terraform-managed LBs for multi-zone ingress distribution.
# These target the fixed NodePorts (30000/30001) on worker nodes.
# The default ingress LB is CCM-managed via nginx Service type LoadBalancer.
locals {
  ingress_load_balancer_pools = [
    for lp in var.ingress_load_balancer_pools : {
      name               = lp.name
      zone               = lp.zone
      load_balancer_type = coalesce(lp.type, var.ingress_load_balancer_type)
      count              = lp.count
      rdns_ipv4 = (
        lp.rdns_ipv4 != null ? lp.rdns_ipv4 :
        lp.rdns != null ? lp.rdns :
        local.ingress_load_balancer_rdns_ipv4
      )
      rdns_ipv6               = null # Scaleway LB IPs are IPv4-only
      load_balancer_algorithm = coalesce(lp.load_balancer_algorithm, var.ingress_load_balancer_algorithm)
      public_network_enabled  = coalesce(lp.public_network_enabled, var.ingress_load_balancer_public_network_enabled)
    }
  ]
  ingress_load_balancer_pools_map = { for lp in local.ingress_load_balancer_pools : lp.name => lp }
}

resource "scaleway_lb_ip" "ingress_pool" {
  for_each = { for k, v in local.ingress_pool_lb_map : k => v if v.public_network_enabled }

  zone    = each.value.zone
  reverse = lookup(local.computed_rdns_for_ingress_pool_lb, each.key, null)
}

locals {
  ingress_pool_lb_map = merge([
    for pool_index in range(length(local.ingress_load_balancer_pools)) : {
      for lb_index in range(local.ingress_load_balancer_pools[pool_index].count) :
      "${var.cluster_name}-${local.ingress_load_balancer_pools[pool_index].name}-${lb_index + 1}" => {
        zone                    = local.ingress_load_balancer_pools[pool_index].zone
        load_balancer_type      = local.ingress_load_balancer_pools[pool_index].load_balancer_type
        load_balancer_algorithm = local.ingress_load_balancer_pools[pool_index].load_balancer_algorithm
        public_network_enabled  = local.ingress_load_balancer_pools[pool_index].public_network_enabled
      }
    }
  ]...)
}

resource "scaleway_ipam_ip" "ingress_pool_lb" {
  for_each = local.ingress_pool_lb_map

  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }

  tags = [var.cluster_name, "role=ingress-pool-lb", "pool=${each.key}"]
}

resource "scaleway_lb" "ingress_pool" {
  for_each = local.ingress_pool_lb_map

  name   = each.key
  ip_ids = each.value.public_network_enabled ? [scaleway_lb_ip.ingress_pool[each.key].id] : []
  zone   = each.value.zone
  type   = each.value.load_balancer_type
  tags   = [var.cluster_name, "role=ingress"]

  external_private_networks = true
}

resource "scaleway_lb_private_network" "ingress_pool" {
  for_each = scaleway_lb.ingress_pool

  lb_id              = each.value.id
  private_network_id = scaleway_vpc_private_network.cluster.id
  zone               = each.value.zone
  ipam_ip_ids        = [scaleway_ipam_ip.ingress_pool_lb[each.key].id]
}

resource "scaleway_lb_backend" "ingress_pool_http" {
  for_each = scaleway_lb.ingress_pool

  lb_id                  = each.value.id
  name                   = "ingress-http"
  forward_protocol       = "tcp"
  forward_port           = local.ingress_nginx_service_node_port_http
  forward_port_algorithm = local.ingress_pool_lb_map[each.key].load_balancer_algorithm
  server_ips             = local.worker_private_ipv4_list

  proxy_protocol = var.ingress_load_balancer_proxy_protocol ? "v2" : "none"

  health_check_tcp {}
  health_check_delay       = "${var.ingress_load_balancer_health_check_interval}s"
  health_check_timeout     = "${var.ingress_load_balancer_health_check_timeout}s"
  health_check_max_retries = var.ingress_load_balancer_health_check_retries

  depends_on = [scaleway_lb_private_network.ingress_pool]
}

resource "scaleway_lb_backend" "ingress_pool_https" {
  for_each = scaleway_lb.ingress_pool

  lb_id                  = each.value.id
  name                   = "ingress-https"
  forward_protocol       = "tcp"
  forward_port           = local.ingress_nginx_service_node_port_https
  forward_port_algorithm = local.ingress_pool_lb_map[each.key].load_balancer_algorithm
  server_ips             = local.worker_private_ipv4_list

  proxy_protocol = var.ingress_load_balancer_proxy_protocol ? "v2" : "none"

  health_check_tcp {}
  health_check_delay       = "${var.ingress_load_balancer_health_check_interval}s"
  health_check_timeout     = "${var.ingress_load_balancer_health_check_timeout}s"
  health_check_max_retries = var.ingress_load_balancer_health_check_retries

  depends_on = [scaleway_lb_private_network.ingress_pool]
}

resource "scaleway_lb_frontend" "ingress_pool_http" {
  for_each = scaleway_lb.ingress_pool

  lb_id        = each.value.id
  backend_id   = scaleway_lb_backend.ingress_pool_http[each.key].id
  name         = "ingress-http"
  inbound_port = 80
}

resource "scaleway_lb_frontend" "ingress_pool_https" {
  for_each = scaleway_lb.ingress_pool

  lb_id        = each.value.id
  backend_id   = scaleway_lb_backend.ingress_pool_https[each.key].id
  name         = "ingress-https"
  inbound_port = 443
}

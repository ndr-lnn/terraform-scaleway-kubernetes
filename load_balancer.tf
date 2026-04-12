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

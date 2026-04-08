locals {
  firewall_external = var.firewall_id != null

  firewall_kube_api_source = (
    var.firewall_kube_api_source != null ?
    var.firewall_kube_api_source :
    var.firewall_api_source
  )
  firewall_talos_api_source = (
    var.firewall_talos_api_source != null ?
    var.firewall_talos_api_source :
    var.firewall_api_source
  )

  firewall_use_current_ipv4 = !local.firewall_external && local.network_public_ipv4_enabled && coalesce(
    var.firewall_use_current_ipv4,
    var.cluster_access == "public" && local.firewall_kube_api_source == null && local.firewall_talos_api_source == null
  )
  firewall_use_current_ipv6 = !local.firewall_external && local.network_public_ipv6_enabled && coalesce(
    var.firewall_use_current_ipv6,
    var.cluster_access == "public" && local.firewall_kube_api_source == null && local.firewall_talos_api_source == null
  )

  current_ip = concat(
    local.firewall_use_current_ipv4 ? ["${chomp(data.http.current_ipv4[0].response_body)}/32"] : [],
    local.firewall_use_current_ipv6 ? (
      strcontains(data.http.current_ipv6[0].response_body, ":") ?
      [cidrsubnet("${chomp(data.http.current_ipv6[0].response_body)}/64", 0, 0)] :
      []
    ) : []
  )

  firewall_kube_api_sources = distinct(compact(concat(
    coalesce(local.firewall_kube_api_source, []),
    coalesce(local.current_ip, [])
  )))
  firewall_talos_api_sources = distinct(compact(concat(
    coalesce(local.firewall_talos_api_source, []),
    coalesce(local.current_ip, [])
  )))

  firewall_default_rules = concat(
    length(local.firewall_kube_api_sources) > 0 ? [
      {
        description = "Allow Incoming Requests to Kube API"
        direction   = "in"
        source_ips  = local.firewall_kube_api_sources
        protocol    = "tcp"
        port        = local.kube_api_port
      }
    ] : [],
    length(local.firewall_talos_api_sources) > 0 ? [
      {
        description = "Allow Incoming Requests to Talos API"
        direction   = "in"
        source_ips  = local.firewall_talos_api_sources
        protocol    = "tcp"
        port        = local.talos_api_port
      }
    ] : [],
  )

  firewall_rules = {
    for rule in local.firewall_default_rules :
    format("%s-%s-%s",
      lookup(rule, "direction", "null"),
      lookup(rule, "protocol", "null"),
      lookup(rule, "port", "null")
    ) => rule
  }
  firewall_extra_rules = {
    for rule in var.firewall_extra_rules :
    format("%s-%s-%s",
      lookup(rule, "direction", "null"),
      lookup(rule, "protocol", "null"),
      coalesce(lookup(rule, "port", "null"), "null")
    ) => rule
  }

  firewall_rules_list = values(
    merge(local.firewall_extra_rules, local.firewall_rules)
  )

  # Flatten firewall rules: Scaleway inbound_rule takes a single ip_range,
  # so we produce one rule entry per (protocol, port, source_ip) tuple.
  firewall_rules_flat = flatten([
    for rule in local.firewall_rules_list : [
      for ip in lookup(rule, "source_ips", []) : {
        protocol = lower(rule.protocol)
        port     = tostring(lookup(rule, "port", null))
        ip_range = ip
      }
    ] if lookup(rule, "direction", "out") == "in"
  ])

  security_group_id = local.firewall_external ? var.firewall_id : scaleway_instance_security_group.this[0].id
}

data "http" "current_ipv4" {
  count = local.firewall_use_current_ipv4 ? 1 : 0
  url   = "https://ipv4.icanhazip.com"

  retry {
    attempts     = 10
    min_delay_ms = 1000
    max_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = contains([200], self.status_code)
      error_message = "HTTP status code invalid"
    }
  }
}

data "http" "current_ipv6" {
  count = local.firewall_use_current_ipv6 ? 1 : 0
  url   = "https://${var.firewall_use_current_ipv6 == true ? "ipv6." : ""}icanhazip.com"

  retry {
    attempts     = 10
    min_delay_ms = 1000
    max_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = contains([200], self.status_code)
      error_message = "HTTP status code invalid"
    }
  }
}

resource "scaleway_instance_security_group" "this" {
  count = local.firewall_external ? 0 : 1

  name                    = var.cluster_name
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = ["cluster:${var.cluster_name}"]

  # Allow all intra-cluster traffic (nodes on the same private network)
  inbound_rule {
    action   = "accept"
    ip_range = local.network_ipv4_cidr
    protocol = "ANY"
  }

  dynamic "inbound_rule" {
    for_each = local.firewall_rules_flat
    content {
      action   = "accept"
      protocol = upper(inbound_rule.value.protocol)
      port     = inbound_rule.value.port != "null" ? tonumber(inbound_rule.value.port) : null
      ip_range = inbound_rule.value.ip_range
    }
  }
}

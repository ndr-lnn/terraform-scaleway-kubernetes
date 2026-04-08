resource "scaleway_instance_placement_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-pg"
  policy_type = "max_availability"

  tags = [var.cluster_name, "role=control-plane"]
}

resource "scaleway_instance_placement_group" "worker" {
  for_each = merge([
    for np in local.worker_nodepools : {
      for i in range(ceil(np.count / 20.0)) : "${var.cluster_name}-${np.name}-pg-${i + 1}" => {
        nodepool = np.name
      }
    } if np.placement_group && np.count > 0
  ]...)

  name        = each.key
  policy_type = "max_availability"

  tags = [var.cluster_name, "nodepool=${each.value.nodepool}", "role=worker"]
}

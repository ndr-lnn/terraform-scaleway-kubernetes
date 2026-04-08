module "kubernetes" {
  source = "../../"

  cluster_name        = var.cluster_name
  scaleway_project_id = var.scaleway_project_id
  scaleway_access_key = var.scaleway_access_key
  scaleway_secret_key = var.scaleway_secret_key
  scaleway_region     = "fr-par"
  scaleway_zone       = "fr-par-1"

  control_plane_nodepools = [
    {
      name = "cp"
      zone = "fr-par-1"
      type = "PRO2-XXS"
    }
  ]

  worker_nodepools = [
    {
      name  = "worker"
      zone  = "fr-par-1"
      type  = "PRO2-S"
      count = 2
    }
  ]
}

output "kubeconfig" {
  value     = module.kubernetes.kubeconfig
  sensitive = true
}

output "talosconfig" {
  value     = module.kubernetes.talosconfig
  sensitive = true
}

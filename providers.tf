provider "scaleway" {
  access_key = var.scaleway_access_key
  secret_key = var.scaleway_secret_key
  project_id = var.scaleway_project_id
  zone       = var.scaleway_zone
  region     = var.scaleway_region
}

provider "helm" {
  repository_config_path = "${path.module}/.helm/repositories.yaml"

  kubernetes = {
    config_path = "${path.module}/.helm/kubeconfig"
  }
}

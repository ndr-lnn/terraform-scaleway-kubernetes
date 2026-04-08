resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

resource "scaleway_iam_ssh_key" "this" {
  name       = "${var.cluster_name}-default"
  public_key = tls_private_key.ssh_key.public_key_openssh
  project_id = var.scaleway_project_id
}

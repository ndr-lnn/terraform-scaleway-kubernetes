# Terraform Scaleway Kubernetes (Talos Linux)

Terraform module for deploying production-grade Kubernetes clusters on [Scaleway](https://www.scaleway.com/) using [Talos Linux](https://www.talos.dev/).

Ported from [terraform-hcloud-kubernetes](https://registry.terraform.io/modules/hcloud-k8s/kubernetes/hcloud/latest) with Scaleway-specific adaptations.

## Features

- **Immutable OS**: Talos Linux -- no SSH, no shell, API-managed only
- **Encryption**: LUKS2 disk encryption (STATE + EPHEMERAL), WireGuard/IPSec via Cilium
- **Networking**: Scaleway VPC with private networks, Cilium CNI with native routing
- **HA Control Plane**: Load balancer-based failover (3+ control plane nodes)
- **Storage**: Scaleway CSI driver with optional LUKS-encrypted volumes, Longhorn support
- **Ingress**: NGINX ingress controller with Scaleway load balancers
- **Security**: Scaleway security groups, mTLS for all APIs, OIDC authentication
- **Observability**: Metrics Server, Prometheus Operator CRDs, Cilium Hubble
- **TLS**: cert-manager with Gateway API support
- **Multi-arch**: AMD64 and ARM64 (COPARM1) instance support

## Prerequisites

- Terraform >= 1.9.0 (or OpenTofu)
- [talosctl](https://www.talos.dev/latest/introduction/getting-started/#talosctl) matching your target Talos version
- `zstd` -- for decompressing Talos images
- `qemu-img` -- for converting images to qcow2 format
- `aws` CLI -- for S3-compatible state tracking
- `curl`, `jq` -- for API interactions

## Usage

### Minimal Example

```hcl
module "kubernetes" {
  source  = "<your-org>/kubernetes/scaleway"
  version = "~> 1.0"

  cluster_name        = "my-cluster"
  scaleway_project_id = var.scaleway_project_id
  scaleway_access_key = var.scaleway_access_key
  scaleway_secret_key = var.scaleway_secret_key

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
```

### HA Cluster with Encryption

```hcl
module "kubernetes" {
  source  = "<your-org>/kubernetes/scaleway"
  version = "~> 1.0"

  cluster_name        = "production"
  scaleway_project_id = var.scaleway_project_id
  scaleway_access_key = var.scaleway_access_key
  scaleway_secret_key = var.scaleway_secret_key
  scaleway_region     = "fr-par"
  scaleway_zone       = "fr-par-1"

  kubernetes_version = "1.32.0"
  talos_version      = "1.11.0"

  control_plane_nodepools = [
    { name = "cp-1", zone = "fr-par-1", type = "PRO2-XXS" },
    { name = "cp-2", zone = "fr-par-1", type = "PRO2-XXS" },
    { name = "cp-3", zone = "fr-par-1", type = "PRO2-XXS" },
  ]

  worker_nodepools = [
    {
      name  = "general"
      zone  = "fr-par-1"
      type  = "PRO2-S"
      count = 3
    }
  ]

  # Encryption
  cilium_encryption_enabled = true
  cilium_encryption_type    = "wireguard"
  talos_state_partition_encryption_enabled     = true
  talos_ephemeral_partition_encryption_enabled = true

  # Components
  cert_manager_enabled   = true
  ingress_nginx_enabled  = true
  metrics_server_enabled = true
  longhorn_enabled       = false
}
```

### Access the Cluster

```bash
export TALOSCONFIG=talosconfig
export KUBECONFIG=kubeconfig

talosctl get member
kubectl get nodes -o wide
```

## Authentication

The module requires Scaleway credentials for both the Terraform provider and the in-cluster CCM/CSI components:

| Variable | Env Var Fallback | Required | Description |
|---|---|---|---|
| `scaleway_project_id` | `SCW_DEFAULT_PROJECT_ID` | Yes | Scaleway project UUID |
| `scaleway_access_key` | `SCW_ACCESS_KEY` | Effectively | API access key (needed for CCM/CSI secrets) |
| `scaleway_secret_key` | `SCW_SECRET_KEY` | Effectively | API secret key (needed for CCM/CSI secrets) |

**Security recommendation**: Create a dedicated IAM application with minimal permissions for the CCM/CSI rather than using your main access key.

## Key Differences from Hetzner Module

| Feature | Hetzner | Scaleway |
|---|---|---|
| Control plane HA | Floating IP VIP | Load balancer (mandatory) |
| Cluster autoscaler | Supported | Not available |
| Image builds | Packer | Terraform-native (zstd + qemu-img) |
| Firewall | hcloud_firewall | Security groups |
| CCM | Official Helm chart | Local Helm chart (bundled) |
| Private cluster NAT | Implicit | Public gateway (explicit) |
| Delete protection | API-level | Terraform lifecycle only |

## Providers

| Provider | Version | Purpose |
|---|---|---|
| [scaleway/scaleway](https://registry.terraform.io/providers/scaleway/scaleway) | ~> 2.47 | Scaleway infrastructure |
| [siderolabs/talos](https://registry.terraform.io/providers/siderolabs/talos) | 0.10.1 | Talos OS provisioning |
| [hashicorp/helm](https://registry.terraform.io/providers/hashicorp/helm) | ~> 3.1.0 | Helm chart rendering |
| [hashicorp/http](https://registry.terraform.io/providers/hashicorp/http) | ~> 3.5.0 | HTTP data sources |
| [hashicorp/tls](https://registry.terraform.io/providers/hashicorp/tls) | ~> 4.2.0 | TLS key generation |
| [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random) | ~> 3.8.0 | Random value generation |

## Terraform Cloud

This module uses `local-exec` provisioners for `talosctl` operations and image building. It is compatible with TF Cloud using **local execution mode** only (`execution_mode = "local"`).

## Outputs

| Output | Sensitive | Description |
|---|---|---|
| `kubeconfig` | Yes | Raw kubeconfig file |
| `talosconfig` | Yes | Raw Talos configuration file |
| `kubeconfig_data` | Yes | Structured kubeconfig data |
| `talosconfig_data` | Yes | Structured Talos config data |
| `control_plane_private_ipv4_list` | No | Control plane private IPs |
| `control_plane_public_ipv4_list` | No | Control plane public IPs |
| `worker_private_ipv4_list` | No | Worker private IPs |
| `worker_public_ipv4_list` | No | Worker public IPs |
| `kube_api_load_balancer` | No | LB details (id, IPs) |
| `cilium_encryption_info` | No | Cilium encryption status |

## License

MIT License. See [LICENSE](LICENSE) for details.

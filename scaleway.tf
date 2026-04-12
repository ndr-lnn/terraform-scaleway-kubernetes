# Scaleway Secret
locals {
  scaleway_secret_manifest = {
    name = "scaleway-secret"
    contents = yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = "scaleway-secret"
        namespace = "kube-system"
      }
      type = "Opaque"
      stringData = {
        SCW_ACCESS_KEY         = var.scaleway_access_key
        SCW_SECRET_KEY         = var.scaleway_secret_key
        SCW_DEFAULT_PROJECT_ID = var.scaleway_project_id
        SCW_DEFAULT_REGION     = var.scaleway_region
        SCW_DEFAULT_ZONE       = var.scaleway_zone
      }
    })
  }
}

# Scaleway CCM
data "helm_template" "scaleway_ccm" {
  count        = var.scaleway_ccm_enabled ? 1 : 0
  name         = "scaleway-ccm"
  namespace    = "kube-system"
  chart        = "${path.module}/charts/scaleway-ccm"
  kube_version = var.kubernetes_version
  values = [
    yamlencode({
      image = { tag = var.scaleway_ccm_version }
      # PN_ID tells CCM to attach LoadBalancer Services to the cluster PN.
      # Bare UUID required — strip the "fr-par/" region prefix from Terraform's ID.
      env = {
        PN_ID = regex("[^/]+$", scaleway_vpc_private_network.cluster.id)
      }
    }),
    yamlencode(var.scaleway_ccm_helm_values),
  ]
}

locals {
  scaleway_ccm_manifest = var.scaleway_ccm_enabled ? {
    name     = "scaleway-ccm"
    contents = data.helm_template.scaleway_ccm[0].manifest
  } : null
}

# Scaleway CSI
resource "random_bytes" "scaleway_csi_encryption_key" {
  count  = var.scaleway_csi_enabled ? 1 : 0
  length = 32
}

locals {
  scaleway_csi_storage_classes = [
    for class in var.scaleway_csi_storage_classes : {
      name                = class.name
      reclaimPolicy       = class.reclaimPolicy
      defaultStorageClass = class.defaultStorageClass

      extraParameters = merge(
        class.encrypted ? {
          "csi.storage.k8s.io/node-publish-secret-name"      = "scaleway-csi-encryption"
          "csi.storage.k8s.io/node-publish-secret-namespace" = "kube-system"
        } : {},
        class.extraParameters
      )
    }
  ]
}

data "helm_template" "scaleway_csi" {
  count        = var.scaleway_csi_enabled ? 1 : 0
  name         = "scaleway-csi"
  namespace    = "kube-system"
  repository   = var.scaleway_csi_helm_repository
  chart        = var.scaleway_csi_helm_chart
  version      = var.scaleway_csi_helm_version
  kube_version = var.kubernetes_version
  values = [
    yamlencode({
      controller = {
        scaleway = {
          env = {
            SCW_ACCESS_KEY         = var.scaleway_access_key
            SCW_SECRET_KEY         = var.scaleway_secret_key
            SCW_DEFAULT_ZONE       = var.scaleway_zone
            SCW_DEFAULT_PROJECT_ID = var.scaleway_project_id
          }
        }
        volumeExtraLabels = var.scaleway_csi_volume_extra_labels
      }
      storageClasses = local.scaleway_csi_storage_classes
    }),
    yamlencode(var.scaleway_csi_helm_values),
  ]
}

locals {
  scaleway_csi_secret_manifest = var.scaleway_csi_enabled ? yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "scaleway-csi-encryption"
      namespace = "kube-system"
    }
    type = "Opaque"
    stringData = {
      encryptionPassphrase = coalesce(var.scaleway_csi_encryption_passphrase, random_bytes.scaleway_csi_encryption_key[0].hex)
    }
  }) : null

  # The Scaleway CSI Helm chart omits namespace from rendered templates (chart bug).
  # We inject "namespace: kube-system" into all resources that have a metadata block
  # but no namespace field, so they deploy to kube-system instead of default.
  scaleway_csi_manifest_raw = var.scaleway_csi_enabled ? data.helm_template.scaleway_csi[0].manifest : ""
  scaleway_csi_manifest_namespaced = replace(
    local.scaleway_csi_manifest_raw,
    "metadata:\n  name:",
    "metadata:\n  namespace: kube-system\n  name:"
  )

  scaleway_csi_manifest = var.scaleway_csi_enabled ? {
    name     = "scaleway-csi"
    contents = join("\n---\n", compact([local.scaleway_csi_secret_manifest, local.scaleway_csi_manifest_namespaced]))
  } : null
}

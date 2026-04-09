locals {
  talos_schematic_id = var.talos_schematic_id != null ? var.talos_schematic_id : talos_image_factory_schematic.this[0].id

  talos_installer_image_url = data.talos_image_factory_urls.amd64.urls.installer
  talos_amd64_image_url     = data.talos_image_factory_urls.amd64.urls.disk_image
  talos_arm64_image_url     = data.talos_image_factory_urls.arm64.urls.disk_image

  amd64_image_required = anytrue([
    for np in concat(
      local.control_plane_nodepools,
      local.worker_nodepools
    ) : !startswith(upper(np.server_type), "COPARM1")
  ])
  arm64_image_required = anytrue([
    for np in concat(
      local.control_plane_nodepools,
      local.worker_nodepools
    ) : startswith(upper(np.server_type), "COPARM1")
  ])

  talos_image_extensions_longhorn = [
    "siderolabs/iscsi-tools",
    "siderolabs/util-linux-tools"
  ]

  talos_image_extensions = distinct(
    concat(
      ["siderolabs/qemu-guest-agent"],
      var.talos_image_extensions,
      var.longhorn_enabled ? local.talos_image_extensions_longhorn : []
    )
  )

  talos_image_amd64_id = local.amd64_image_required ? scaleway_instance_image.talos_amd64[0].id : null
  talos_image_arm64_id = local.arm64_image_required ? scaleway_instance_image.talos_arm64[0].id : null
}

data "talos_image_factory_extensions_versions" "this" {
  count = var.talos_schematic_id == null ? 1 : 0

  talos_version = var.talos_version
  filters = {
    names = local.talos_image_extensions
  }
}

resource "talos_image_factory_schematic" "this" {
  count = var.talos_schematic_id == null ? 1 : 0

  schematic = yamlencode(
    {
      customization = {
        extraKernelArgs = var.talos_extra_kernel_args
        systemExtensions = {
          officialExtensions = (
            length(local.talos_image_extensions) > 0 ?
            data.talos_image_factory_extensions_versions.this[0].extensions_info.*.name :
            []
          )
        }
      }
    }
  )
}

data "talos_image_factory_urls" "amd64" {
  talos_version = var.talos_version
  schematic_id  = local.talos_schematic_id
  platform      = "scaleway"
  architecture  = "amd64"
}

data "talos_image_factory_urls" "arm64" {
  talos_version = var.talos_version
  schematic_id  = local.talos_schematic_id
  platform      = "scaleway"
  architecture  = "arm64"
}

# ─── Download + Convert (AMD64) ─────────────────────────────────────────────

resource "terraform_data" "talos_image_download_amd64" {
  count = local.amd64_image_required ? 1 : 0

  triggers_replace = [var.talos_version, local.talos_schematic_id]

  provisioner "local-exec" {
    command     = <<-EOT
      set -eu
      CACHE_DIR="${path.module}/.cache/${var.talos_version}-${local.talos_schematic_id}"
      mkdir -p "$CACHE_DIR"
      cd "$CACHE_DIR"
      if [ ! -f "talos-amd64.qcow2" ]; then
        echo "Downloading Talos amd64 image..."
        wget -q "${local.talos_amd64_image_url}" -O talos-amd64.raw.zst
        echo "Decompressing..."
        zstd --decompress --force talos-amd64.raw.zst
        echo "Converting to qcow2..."
        qemu-img convert -f raw -O qcow2 talos-amd64.raw talos-amd64.qcow2
        rm -f talos-amd64.raw.zst talos-amd64.raw
        echo "Done: talos-amd64.qcow2"
      else
        echo "Image already cached"
      fi
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# ─── Download + Convert (ARM64) ─────────────────────────────────────────────

resource "terraform_data" "talos_image_download_arm64" {
  count = local.arm64_image_required ? 1 : 0

  triggers_replace = [var.talos_version, local.talos_schematic_id]

  provisioner "local-exec" {
    command     = <<-EOT
      set -eu
      CACHE_DIR="${path.module}/.cache/${var.talos_version}-${local.talos_schematic_id}"
      mkdir -p "$CACHE_DIR"
      cd "$CACHE_DIR"
      if [ ! -f "talos-arm64.qcow2" ]; then
        echo "Downloading Talos arm64 image..."
        wget -q "${local.talos_arm64_image_url}" -O talos-arm64.raw.zst
        echo "Decompressing..."
        zstd --decompress --force talos-arm64.raw.zst
        echo "Converting to qcow2..."
        qemu-img convert -f raw -O qcow2 talos-arm64.raw talos-arm64.qcow2
        rm -f talos-arm64.raw.zst talos-arm64.raw
        echo "Done: talos-arm64.qcow2"
      else
        echo "Image already cached"
      fi
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# ─── S3 Bucket for Image Storage ────────────────────────────────────────────

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "scaleway_object_bucket" "talos_images" {
  name   = "${var.cluster_name}-talos-${random_id.bucket_suffix.hex}"
  region = var.scaleway_region

  lifecycle {
    prevent_destroy = true
  }
}

# ─── Upload Images to S3 ────────────────────────────────────────────────────

resource "scaleway_object" "talos_image_amd64" {
  count = local.amd64_image_required ? 1 : 0

  bucket = scaleway_object_bucket.talos_images.name
  key    = "talos-${var.talos_version}-${local.talos_schematic_id}/talos-amd64.qcow2"
  file   = "${path.module}/.cache/${var.talos_version}-${local.talos_schematic_id}/talos-amd64.qcow2"
  region = var.scaleway_region

  depends_on = [terraform_data.talos_image_download_amd64]
}

resource "scaleway_object" "talos_image_arm64" {
  count = local.arm64_image_required ? 1 : 0

  bucket = scaleway_object_bucket.talos_images.name
  key    = "talos-${var.talos_version}-${local.talos_schematic_id}/talos-arm64.qcow2"
  file   = "${path.module}/.cache/${var.talos_version}-${local.talos_schematic_id}/talos-arm64.qcow2"
  region = var.scaleway_region

  depends_on = [terraform_data.talos_image_download_arm64]
}

# ─── Snapshot Import ────────────────────────────────────────────────────────

resource "scaleway_instance_snapshot" "talos_amd64" {
  count = local.amd64_image_required ? 1 : 0

  name = "talos-${var.talos_version}-${local.talos_schematic_id}-amd64"
  import {
    bucket = scaleway_object.talos_image_amd64[0].bucket
    key    = scaleway_object.talos_image_amd64[0].key
  }
  tags = [var.cluster_name, "os=talos", "talos_version=${var.talos_version}", "arch=amd64"]
}

resource "scaleway_instance_snapshot" "talos_arm64" {
  count = local.arm64_image_required ? 1 : 0

  name = "talos-${var.talos_version}-${local.talos_schematic_id}-arm64"
  import {
    bucket = scaleway_object.talos_image_arm64[0].bucket
    key    = scaleway_object.talos_image_arm64[0].key
  }
  tags = [var.cluster_name, "os=talos", "talos_version=${var.talos_version}", "arch=arm64"]
}

# ─── Bootable Images ────────────────────────────────────────────────────────

resource "scaleway_instance_image" "talos_amd64" {
  count = local.amd64_image_required ? 1 : 0

  name           = "talos-${var.talos_version}-${local.talos_schematic_id}-amd64"
  root_volume_id = scaleway_instance_snapshot.talos_amd64[0].id
  architecture   = "x86_64"
  tags           = [var.cluster_name, "os=talos", "talos_version=${var.talos_version}"]
}

resource "scaleway_instance_image" "talos_arm64" {
  count = local.arm64_image_required ? 1 : 0

  name           = "talos-${var.talos_version}-${local.talos_schematic_id}-arm64"
  root_volume_id = scaleway_instance_snapshot.talos_arm64[0].id
  architecture   = "arm64"
  tags           = [var.cluster_name, "os=talos", "talos_version=${var.talos_version}"]
}

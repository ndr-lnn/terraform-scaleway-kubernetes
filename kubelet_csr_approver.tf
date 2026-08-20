# ─── Kubelet Serving Certificate CSR Approver ───────────────────────────────
#
# Talos sets `rotate-server-certificates = true` (talos_config_base.tf), which
# makes every kubelet request a SERVING certificate through the CSR API. Nothing
# in a stock cluster approves those.
#
# Kubernetes' built-in certificate controller only auto-approves the two CLIENT
# signers — `certificatesigningrequests:nodeclient` and `:selfnodeclient`. There
# is deliberately no built-in approver for `kubernetes.io/kubelet-serving`,
# because approving it means asserting that the SANs in the request really do
# belong to that node, and the API server cannot know that on its own.
#
# Left unattended the CSRs simply pile up Pending, and the visible symptoms are
# indirect and easy to misattribute:
#   - `kubectl logs` / `kubectl exec` fail with `tls: internal error`
#   - metrics-server cannot scrape, so `kubectl top` and any HPA driven by it
#     silently degrade
# A cluster keeps working until its last approved certificate expires, which is
# why this can sit latent for a year and then surface on a schedule.
#
# This controller closes the gap without blanket-approving anything: for each
# CSR it checks the node name against `providerRegex` and verifies the requested
# SANs actually belong to that node, then approves or denies.
#
# ⚠️ `bypassDnsResolution` defaults to true here on purpose. The upstream default
# resolves the node name in DNS and requires it to match the SAN IPs. Talos node
# names are not registered in any DNS zone, so with resolution enabled every CSR
# is DENIED — a worse failure than leaving them Pending, because a denied CSR is
# not retried. `providerRegex` is what constrains approval instead, so it is
# validated as non-empty below rather than being allowed to default to ".*".

locals {
  # ⚠️ providerRegex is matched against EVERY DNS SAN in the request, not just
  # the node name. On Scaleway the CCM publishes an ExternalDNS node address of
  # the form <instance-uuid>.pub.instances.scw.cloud, and the kubelet copies it
  # into the serving-cert SANs alongside the node name. A regex anchored only to
  # the cluster name therefore DENIES every worker CSR.
  #
  # Both alternatives are required. Verified against a real request:
  #   DNS:8c74....pub.instances.scw.cloud, DNS:<cluster>-worker-2,
  #   IP:<private>, IP:<public>
  kubelet_csr_approver_provider_regex = coalesce(
    var.kubelet_csr_approver_provider_regex,
    "^(${var.cluster_name}-[a-z0-9.-]+|[0-9a-f-]+\\.pub\\.instances\\.scw\\.cloud)$"
  )

  kubelet_csr_approver_replicas = min(
    var.kubelet_csr_approver_replicas,
    max(local.control_plane_sum, 1)
  )
}

data "helm_template" "kubelet_csr_approver" {
  count = var.kubelet_csr_approver_enabled ? 1 : 0

  name      = "kubelet-csr-approver"
  namespace = "kube-system"

  repository   = var.kubelet_csr_approver_helm_repository
  chart        = var.kubelet_csr_approver_helm_chart
  version      = var.kubelet_csr_approver_helm_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      replicas            = local.kubelet_csr_approver_replicas
      providerRegex       = local.kubelet_csr_approver_provider_regex
      bypassDnsResolution = var.kubelet_csr_approver_bypass_dns_resolution
      leaderElection      = local.kubelet_csr_approver_replicas > 1

      # Two DNS SANs on Scaleway: the node name plus the CCM's ExternalDNS
      # entry. The chart default of 1 denies every worker CSR.
      allowedDnsNames = var.kubelet_csr_approver_allowed_dns_names

      # The approver otherwise requires every additional DNS SAN to be PREFIXED
      # by the node name (e.g. node.example.com). Scaleway's UUID-based public
      # DNS name can never satisfy that, so the check has to be off or no worker
      # CSR is ever approvable. providerRegex remains the boundary.
      bypassHostnameCheck = var.kubelet_csr_approver_bypass_hostname_check

      # Runs on the control plane: it is a cluster-critical admission-time
      # component, and a worker-only placement would make new-worker bring-up
      # depend on worker capacity being available already.
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          effect   = "NoSchedule"
          operator = "Exists"
        }
      ]
      nodeSelector = {
        "node-role.kubernetes.io/control-plane" = ""
      }

      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }),
    yamlencode(var.kubelet_csr_approver_helm_values)
  ]
}

locals {
  kubelet_csr_approver_manifest = var.kubelet_csr_approver_enabled ? {
    name     = "kubelet-csr-approver"
    contents = data.helm_template.kubelet_csr_approver[0].manifest
  } : null
}

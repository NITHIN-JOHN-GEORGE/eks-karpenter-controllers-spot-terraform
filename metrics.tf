resource "helm_release" "metrics-server" {
    depends_on = [helm_release.karpenter , kubectl_manifest.karpenter-provisioner ]
    name        = "metrics-server"
    chart       = "metrics-server"
    repository  = "https://kubernetes-sigs.github.io/metrics-server/"
    version     = "3.8.2"
    namespace   = "kube-system"
    description = "Metric server helm Chart deployment configuration"
}


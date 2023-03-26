# eks-karpenter-controllers-spot-terraform
Maximizing Cost-Efficiency with Karpenter: Setting Up EKS Cluster (v1.24) on Spot-Instances with AWS ALB Ingress Controller, Amazon EBS CSI Driver, and Add-ons

We will be provisioning  EKS Kubernetes cluster at any scale using Karpenter . We will also utilize spot instances to reduce costs by up to 90 percent.  Additionally, we'll set up the AWS ALB Ingress Controller and Amazon EBS CSI driver, establish trust between an OIDC-compatible identity provider and your AWS account using IAM OIDC identity provider (including the necessary IAM roles and policies), install the metrics server, and set up required EKS add-ons using Terraform. We will deploy all of this using Helm charts and configure custom values.yml using Terraform as well. Finally, we will use Terraform Cloud for remote state, creating workspaces, and the plan/apply workflow.

Medium Link: https://medium.com/@nithinjohn97/maximizing-cost-efficiency-with-karpenter-setting-up-eks-cluster-v1-24-b68bbd64f23c

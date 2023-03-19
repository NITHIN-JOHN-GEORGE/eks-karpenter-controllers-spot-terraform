# IAM role for EKS cluster 

resource "aws_iam_role" "EKSClusterRole" {
  count                = contains(local.env, var.env) ? 1 : 0
  name = "EKSClusterRole_v2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

# Adding policies to the IAM role for EKS cluster

resource "aws_iam_role_policy_attachment" "eks-cluster-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = element(aws_iam_role.EKSClusterRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "eks-cluster-AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = element(aws_iam_role.EKSClusterRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "eks-cluster-AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = element(aws_iam_role.EKSClusterRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "eks_CloudWatchFullAccess" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
  role       =element(aws_iam_role.EKSClusterRole.*.name,0)
}


## IAM role for Node group

resource "aws_iam_role" "NodeGroupRole" {
  count                = contains(local.env, var.env) ? 1 : 0
  name = "EKSNodeGroupRole_v2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

#---policy-attachements-for-Node group-role--------

resource "aws_iam_role_policy" "node-group-ClusterAutoscalerPolicy" {
  name = "eks-cluster-auto-scaler"
  role = element(aws_iam_role.NodeGroupRole.*.id,0)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
            "autoscaling:DescribeAutoScalingGroups",
            "autoscaling:DescribeAutoScalingInstances",
            "autoscaling:DescribeLaunchConfigurations",
            "autoscaling:DescribeTags",
            "autoscaling:SetDesiredCapacity",
            "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_group_AWSLoadBalancerControllerPolicy" {
  policy_arn = element(aws_iam_policy.load-balancer-policy.*.arn,0)
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}


resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}

resource "aws_iam_role_policy_attachment" "CloudWatchAgentServerPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}

## SSMManagedInstanceCore Policy for Nodes (Karpenter)
resource "aws_iam_role_policy_attachment" "eks_node_attach_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = element(aws_iam_role.NodeGroupRole.*.name,0)
}

# Create IAM OIDC identity providers to establish trust between an OIDC-compatible IdP and your AWS account.

data "tls_certificate" "cert" {
  url = aws_eks_cluster.eks-cluster[0].identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cert.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks-cluster[0].identity[0].oidc[0].issuer
}
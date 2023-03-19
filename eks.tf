locals {
  env = ["prod", "qa", "dev"]
}


#------------Security group for eks-cluster--------------------------------------------------

resource "aws_security_group" "control_plane_sg" {
  count                = contains(local.env, var.env) ? 1 : 0
  name   = "k8s-control-plane-sg"
  vpc_id = "${data.aws_vpc.vpc.id}"

  tags = {
    Name = "k8s-control-plane-sg"
    vpc_id = "${data.aws_vpc.vpc.id}"
    ManagedBy = "terraform"
    Env       = var.env
    "karpenter.sh/discovery" = var.cluster_name
  }
}

#----------------------Security group traffic rules for eks cluster------------------------------------------

## Ingress rule
resource "aws_security_group_rule" "control_plane_inbound" {
  description   = "Allow worker Kubelets and pods to receive communication from the cluster control plane"  
  security_group_id = element(aws_security_group.control_plane_sg.*.id,0)
  type              = "ingress"
  from_port   = 0
  to_port     = 65535
  protocol    = "tcp"
  cidr_blocks = flatten(["${values(data.aws_subnet.public_subnets).*.cidr_block}", "${values(data.aws_subnet.private_subnets).*.cidr_block}"])
}

## Egress rule
resource "aws_security_group_rule" "control_plane_outbound" {
  security_group_id = element(aws_security_group.control_plane_sg.*.id,0)
  type              = "egress"
  from_port   = 0
  to_port     = 65535
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

#------------Security group for eks-nodes--------------------------------------------------

resource "aws_security_group" "eks-nodes" {
  count                = contains(local.env, var.env) ? 1 : 0
  name        = "nodes_eks_sg"
  description = "nodes_eks_sg"
  vpc_id      = "${data.aws_vpc.vpc.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nodes_eks_sg"
    vpc_id = "${data.aws_vpc.vpc.id}"
    ManagedBy = "terraform"
    Env       = var.env
    "karpenter.sh/discovery" = var.cluster_name
  }
}

#---------Security group traffic rules for node-security-group----------------

## Ingress rule
resource "aws_security_group_rule" "nodes_ssh" {
  security_group_id =  element(aws_security_group.eks-nodes.*.id,0)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = flatten(["${values(data.aws_subnet.public_subnets).*.cidr_block}", "${values(data.aws_subnet.private_subnets).*.cidr_block}"])
}

#--------------------cloud-watch-log-group-- for eks cluster----------------------------------------------

resource "aws_cloudwatch_log_group" "eks_log_group" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.retention_day
  tags = {
    Name = "/aws/eks/${var.cluster_name}/cluster"
    vpc_id = "${data.aws_vpc.vpc.id}"
    ManagedBy = "terraform"
    Env       = var.env
  }
  
}

#-----------------EKS-cluster-code--------------------------------------------

resource "aws_eks_cluster" "eks-cluster" {
  count                = contains(local.env, var.env) ? 1 : 0
  name     = "${var.cluster_name}"
  enabled_cluster_log_types = ["api","audit","authenticator","controllerManager","scheduler"]
  version  = "${var.eks_version}"
  role_arn = element(aws_iam_role.EKSClusterRole.*.arn,0)

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids = ["${element(aws_security_group.control_plane_sg.*.id,0)}"]
    subnet_ids         = flatten(["${values(data.aws_subnet.private_subnets).*.id}"])
  }

  tags = {
    Name = "${var.cluster_name}"
    vpc_id = "${data.aws_vpc.vpc.id}"
    ManagedBy = "terraform"
    "karpenter.sh/discovery" = var.cluster_name
    Env       = var.env
  }

  depends_on = [
    aws_cloudwatch_log_group.eks_log_group,
    aws_iam_role_policy_attachment.eks-cluster-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks-cluster-AmazonEKSServicePolicy,
  ]
}

#--------------eks-private-node-group----------------------------------------------

resource "aws_eks_node_group" "node-group-private" {
  cluster_name    = element(aws_eks_cluster.eks-cluster.*.name,0)
  node_group_name = var.node_group_name
  node_role_arn   = element(aws_iam_role.NodeGroupRole.*.arn,0)
  subnet_ids      = flatten(["${values(data.aws_subnet.private_subnets).*.id}"])
  capacity_type  = "ON_DEMAND"

  ami_type       = var.ami_type
  disk_size      = var.disk_size
  instance_types = var.instance_types

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }
  
  lifecycle {
    create_before_destroy = true
  }

  timeouts {}

  remote_access {
    ec2_ssh_key = var.ec2_ssh_key_name_eks_nodes
    source_security_group_ids = [element(aws_security_group.eks-nodes.*.id,0)]

  }
   
  labels         = {
    "eks/cluster-name"   = element(aws_eks_cluster.eks-cluster.*.name,0)
    "eks/nodegroup-name" = format("nodegroup_%s", lower(element(aws_eks_cluster.eks-cluster.*.name,0)))
  }


  tags = merge({
    Name                 = var.node_group_name
    "eks/cluster-name"   = element(aws_eks_cluster.eks-cluster.*.name,0)
    "eks/nodegroup-name" = format("nodegroup_%s", lower(element(aws_eks_cluster.eks-cluster.*.name,0)))
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery/${var.cluster_name}" = var.cluster_name
    "karpenter.sh/discovery" = var.cluster_name
    "eks/nodegroup-type" = "managed"
    vpc_id = "${data.aws_vpc.vpc.id}"
    ManagedBy = "terraform"
    Env       = var.env

  })

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_eks_cluster.eks-cluster,
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
  ]
}



# ADD-ONS

resource "aws_eks_addon" "addons" {
  for_each          = { for addon in var.addons : addon.name => addon }
  cluster_name      = element(aws_eks_cluster.eks-cluster.*.name,0)
  addon_name        = each.value.name
  resolve_conflicts = "OVERWRITE"
}

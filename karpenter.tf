data "aws_ecrpublic_authorization_token" "token" {}

## Karpenter Controller

data "aws_iam_policy_document" "karpenter_controller_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    principals {
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}"
      ]
      type = "Federated"
    }
  }
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
}

data "aws_iam_policy_document" "karpenter" {
  statement {
    resources = ["*"]
    actions   = ["ec2:DescribeImages", "ec2:RunInstances", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeLaunchTemplates", "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeAvailabilityZones", "ec2:DeleteLaunchTemplate", "ec2:CreateTags", "ec2:CreateLaunchTemplate", "ec2:CreateFleet", "ec2:DescribeSpotPriceHistory", "pricing:GetProducts", "ssm:GetParameter"]
    effect    = "Allow"
  }
  statement {
    resources = ["*"]
    actions   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate" , "ec2:RequestSpotInstances" , "ec2:DescribeInstanceStatus" , "iam:CreateServiceLinkedRole" , "iam:ListRoles" , "iam:ListInstanceProfiles"]
    effect    = "Allow"
    # Make sure Karpenter can only delete nodes that it has provisioned
    condition {
      test     = "StringEquals"
      values   = [var.eks_cluster_name]
      variable = "ec2:ResourceTag/karpenter.sh/discovery"
    }
  }
  statement {
    resources = [data.aws_eks_cluster.cluster.arn]
    actions   = ["eks:DescribeCluster"]
    effect    = "Allow"
  }
  statement {
    resources = [ data.aws_iam_role.NodeGroupRole.arn ]
    actions   = ["iam:PassRole"]
    effect    = "Allow"
  }
  # Optional: Interrupt Termination Queue permissions, provided by AWS SQS
  statement {
    resources = [aws_sqs_queue.karpenter.arn]
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes", "sqs:ReceiveMessage"]
    effect    = "Allow"
  }
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
}

resource "aws_iam_role" "karpenter_controller" {
  description        = "IAM Role for Karpenter Controller (pod) to assume"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role_policy.json
  name               = "karpenter-controller"
  inline_policy {
    policy = data.aws_iam_policy_document.karpenter.json
    name   = "karpenter"
  }

  depends_on = [ aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private , data.aws_iam_policy_document.karpenter_controller_assume_role_policy , data.aws_iam_policy_document.karpenter]
}

## Karpenter Instance Profile


resource "aws_iam_instance_profile" "karpenter" {
  name = "karpenter-instance-profile"
  role = data.aws_iam_role.NodeGroupRole.name
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
}

#### Enable Interruption Handling ####

# SQS Queue

resource "aws_sqs_queue" "karpenter" {
  message_retention_seconds = 300
  name   = "${var.eks_cluster_name}-karpenter-sqs-queue"
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
}


# Node termination queue policy

resource "aws_sqs_queue_policy" "karpenter" {
  policy    = data.aws_iam_policy_document.node_termination_queue.json
  queue_url = aws_sqs_queue.karpenter.url
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
}

data "aws_iam_policy_document" "node_termination_queue" {
  depends_on = [aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
  statement {
    resources = [aws_sqs_queue.karpenter.arn]
    sid       = "SQSWrite"
    actions   = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_event_rule" "scheduled_change_rule" {
  name        = "ScheduledChangeRule"
  description = "AWS Health Event"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail_type = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_rule" "spot_interruption_rule" {
  name        = "SpotInterruptionRule"
  description = "EC2 Spot Instance Interruption Warning"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail_type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_rule" "rebalance_rule" {
  name        = "RebalanceRule"
  description = "EC2 Instance Rebalance Recommendation"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail_type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_rule" "instance_state_change_rule" {
  name        = "InstanceStateChangeRule"
  description = "EC2 Instance State-change Notification"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail_type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "scheduled_change_rule" {
  rule      = aws_cloudwatch_event_rule.scheduled_change_rule.name
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_target" "spot_interruption_rule" {
  rule      = aws_cloudwatch_event_rule.spot_interruption_rule.name
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_target" "rebalance_rule" {
  rule      = aws_cloudwatch_event_rule.rebalance_rule.name
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_target" "instance_state_change_rule" {
  rule      = aws_cloudwatch_event_rule.instance_state_change_rule.name
  arn       = aws_sqs_queue.karpenter.arn
}


data "template_file" "karpenter" {
  template = <<EOF
serviceAccount:
   annotations:
       eks.amazonaws.com/role-arn: "${aws_iam_role.karpenter_controller.arn}"
settings:
  aws:
    clusterName: "${data.aws_eks_cluster.cluster.id}"
    clusterEndpoint: "${data.aws_eks_cluster.cluster.endpoint}"
    defaultInstanceProfile: "${aws_iam_instance_profile.karpenter.name}"
    interruptionQueueName: "${var.eks_cluster_name}-karpenter-sqs-queue"
   EOF
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version    = "v0.27.0"  
  values = [data.template_file.karpenter.rendered]

  depends_on = [ aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private , aws_iam_role.karpenter_controller , aws_iam_instance_profile.karpenter , aws_sqs_queue.karpenter ]

}


resource "kubectl_manifest" "karpenter-provisioner" {
    depends_on = [ helm_release.karpenter , aws_eks_cluster.eks-cluster , aws_eks_node_group.node-group-private ]
    yaml_body = <<YAML
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: karpenter-default
  namespace: karpenter
spec:
  provider:
    securityGroupSelector:
      karpenter.sh/discovery: "${var.eks_cluster_name}"
    subnetSelector:
      karpenter.sh/discovery: "${var.eks_cluster_name}"
    tags:
      karpenter.sh/discovery: "${var.eks_cluster_name}"
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot"]
    - key: "node.kubernetes.io/instance-type"
      operator: In
      values: ["t3a.micro" , "t3a.medium" , "t3a.large" ]
    - key: "topology.kubernetes.io/zone"
      operator: In
      values: ["us-east-1a", "us-east-1b" , "us-east-1c"]
    - key: created-by
      operator: In
      values: ["karpenter"]
  ttlSecondsAfterEmpty: 30
YAML
}


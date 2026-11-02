# A small EKS cluster with the demo application the agents investigate and repair.
# One t4g.small node, a single NAT gateway. Run scripts/teardown.sh when you stop.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name}-vpc"
  cidr = "10.42.0.0/16"
  azs  = local.azs

  private_subnets = ["10.42.1.0/24", "10.42.2.0/24"]
  public_subnets  = ["10.42.101.0/24", "10.42.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "lab" {
  name     = "${local.name}-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  # Access is managed with EKS access entries only (no aws-auth ConfigMap).
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_private_access = true # the tool Lambdas use the private endpoint
    endpoint_public_access  = true # only for you, from admin_cidr
    public_access_cidrs     = [var.admin_cidr]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${local.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "lab" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = module.vpc.private_subnets
  ami_type        = "AL2023_ARM_64_STANDARD"
  instance_types  = ["t4g.small"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

# The two tool Lambdas reach the API server on its private endpoint.
resource "aws_security_group_rule" "lambda_to_eks_api" {
  type                     = "ingress"
  description              = "Tool Lambdas to the EKS API"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.lab.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.tools.id
}

# Each tool Lambda maps to its own Kubernetes group. manifests/rbac.yaml
# gives the read group read-only access and the write group one patch right.
resource "aws_eks_access_entry" "tools" {
  for_each = local.tools

  cluster_name      = aws_eks_cluster.lab.name
  principal_arn     = aws_iam_role.tool[each.key].arn
  kubernetes_groups = [each.value.k8s_group]
  type              = "STANDARD"
}

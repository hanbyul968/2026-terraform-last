terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Bastion ??Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# SQS Queue
resource "aws_sqs_queue" "order" {
  name = "skm-order-queue"
}

# VPC for EKS
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "skm-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "skm-igw" }
}

resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = {
    Name                                    = "skm-pub-a"
    "kubernetes.io/cluster/skm-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                = "1"
  }
}

resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2b"
  map_public_ip_on_launch = true
  tags = {
    Name                                    = "skm-pub-b"
    "kubernetes.io/cluster/skm-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "skm-pub-rt" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.public.id
}

locals {
  subnet_ids = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "skm-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "skm-eks-cluster"
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = local.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = false
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# === Ï±ÑÏ†ê?? terraform???§Ìñâ??IAM Ï£ºÏ≤¥??EKS Cluster Admin Î∂Ä??===
# ?Ä????terraform??apply??Í≥ÑÏ†ï(IAM User/Role)??CloudShell?êÏÑú kubectlÎ°?# Ï±ÑÏ†ê?????àÎèÑÎ°? ?∏Ï∂ú Ï£ºÏ≤¥??AmazonEKSClusterAdminPolicy access entryÎ•??∞Í≤∞?úÎã§.
locals {
  caller_arn = data.aws_caller_identity.current.arn
  # STS assumed-role ?∏ÏÖò ARN(arn:aws:sts::...:assumed-role/ROLE/SESSION)??  # access entryÍ∞Ä ?îÍµ¨?òÎäî IAM Role ARN(arn:aws:iam::...:role/ROLE)?ºÎ°ú Î≥Ä??
  # IAM User ARN(arn:aws:iam::...:user/NAME)?Ä Í∑∏Î?Î°??¨Ïö©.
  grader_principal_arn = can(regex(":assumed-role/", local.caller_arn)) ? format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.current.account_id,
    element(split("/", local.caller_arn), 1)
  ) : local.caller_arn
}

resource "aws_eks_access_entry" "creator" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.grader_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "creator" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.grader_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.creator]
}

# Addon NodeGroup IAM Role
resource "aws_iam_role" "addon_ng" {
  name = "skm-cluster-addon-ng-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "addon_ng_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.addon_ng.name
}

resource "aws_iam_role_policy_attachment" "addon_ng_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.addon_ng.name
}

resource "aws_iam_role_policy_attachment" "addon_ng_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.addon_ng.name
}

# EKS managed node group tags are NOT propagated to EC2 instances; LT tag_specifications
# is required for grading 3-2 (tag:Name=skm-cluster-addon-ng-node).
resource "aws_launch_template" "addon_ng" {
  name_prefix = "skm-cluster-addon-ng-"
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "skm-cluster-addon-ng-node" }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "skm-cluster-addon-ng-node" }
  }
  tags = { Name = "skm-cluster-addon-ng-lt" }
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "skm-cluster-addon-ng"
  node_role_arn   = aws_iam_role.addon_ng.arn
  subnet_ids      = local.subnet_ids
  instance_types  = ["t3.medium"]

  launch_template {
    id      = aws_launch_template.addon_ng.id
    version = aws_launch_template.addon_ng.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  taint {
    key    = "dedicated"
    value  = "addon"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name = "skm-cluster-addon-ng-node"
  }

  depends_on = [
    aws_iam_role_policy_attachment.addon_ng_worker,
    aws_iam_role_policy_attachment.addon_ng_cni,
    aws_iam_role_policy_attachment.addon_ng_ecr,
    aws_route_table_association.pub_a,
    aws_route_table_association.pub_b,
  ]
}

# IRSA for KEDA (SQS access)
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_provider = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# IRSA for App (SQS access)
resource "aws_iam_role" "app_irsa" {
  name = "skm-order-processor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:skillsmkt:order-processor-sa"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "app_sqs" {
  name = "skm-order-processor-sqs-policy"
  role = aws_iam_role.app_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.order.arn
    }]
  })
}

# IRSA for KEDA
resource "aws_iam_role" "keda_irsa" {
  name = "skm-keda-operator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:keda:keda-operator"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "keda_sqs" {
  name = "skm-keda-sqs-policy"
  role = aws_iam_role.keda_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      Resource = aws_sqs_queue.order.arn
    }]
  })
}

# IRSA for Karpenter
resource "aws_iam_role" "karpenter_irsa" {
  name = "skm-karpenter-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter" {
  name = "skm-karpenter-policy"
  role = aws_iam_role.karpenter_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.addon_ng.arn
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = aws_eks_cluster.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/eks/optimized-ami/*"
      }
    ]
  })
}

# CoreDNS addon with toleration
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  configuration_values = jsonencode({
    tolerations = [{
      key    = "dedicated"
      value  = "addon"
      effect = "NoSchedule"
    }]
  })

  depends_on = [aws_eks_node_group.addon]
}

output "sqs_queue_url" {
  value = aws_sqs_queue.order.url
}

output "app_irsa_role_arn" {
  value = aws_iam_role.app_irsa.arn
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}


# ============================================================
# ?úÍ≥µ?åÏùº(app/) ÎπåÎìú & Î∞∞Ìè¨??Bastion EC2 ?êÏÑú ?òÌñâ?úÎã§.
# terraform apply ??ECR/S3/Bastion ÍπåÏ?Îß?ÎßåÎì§Í≥? ?§Ï†ú docker build¬∑helm¬∑kubectl
# ?Ä SSM Session Manager Î°?Bastion ???ëÏÜç??/opt/deploy/deploy.sh Î•??§Ìñâ?úÎã§.
# (Î°úÏª¨??Docker Desktop Î∂àÌïÑ????Î°úÏª¨?Ä terraform apply Îß?
# ============================================================

resource "aws_ecr_repository" "app" {
  name                 = "skm-order-processor"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

locals {
  ecr_image = "${aws_ecr_repository.app.repository_url}:latest"

  rendered_karpenter = templatefile("${path.module}/k8s-karpenter.yaml", {
    CLUSTER_NAME   = aws_eks_cluster.main.name
    NODE_ROLE_NAME = aws_iam_role.addon_ng.name
  })
  rendered_app = templatefile("${path.module}/k8s-app.yaml", {
    APP_IRSA_ROLE_ARN = aws_iam_role.app_irsa.arn
    ECR_IMAGE         = local.ecr_image
    SQS_QUEUE_URL     = aws_sqs_queue.order.url
  })
  rendered_keda = templatefile("${path.module}/k8s-keda.yaml", {
    SQS_QUEUE_URL = aws_sqs_queue.order.url
  })
}

# --- Î∞∞Ìè¨ Î≤àÎì§ S3 Î≤ÑÌÇ∑ (app ?åÏä§ + ?åÎçîÎßÅÎêú Îß§Îãà?òÏä§??+ env/deploy ?§ÌÅ¨Î¶ΩÌä∏) ---
resource "aws_s3_bucket" "deploy" {
  bucket        = "skm-deploy-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "app_py" {
  bucket = aws_s3_bucket.deploy.id
  key    = "app.py"
  source = "${path.module}/app/app.py"
  etag   = filemd5("${path.module}/app/app.py")
}
resource "aws_s3_object" "dockerfile" {
  bucket = aws_s3_bucket.deploy.id
  key    = "Dockerfile"
  source = "${path.module}/app/Dockerfile"
  etag   = filemd5("${path.module}/app/Dockerfile")
}
resource "aws_s3_object" "requirements" {
  bucket = aws_s3_bucket.deploy.id
  key    = "requirements.txt"
  source = "${path.module}/app/requirements.txt"
  etag   = filemd5("${path.module}/app/requirements.txt")
}
resource "aws_s3_object" "m_karpenter" {
  bucket  = aws_s3_bucket.deploy.id
  key     = "karpenter.yaml"
  content = local.rendered_karpenter
}
resource "aws_s3_object" "m_app" {
  bucket  = aws_s3_bucket.deploy.id
  key     = "app.yaml"
  content = local.rendered_app
}
resource "aws_s3_object" "m_keda" {
  bucket  = aws_s3_bucket.deploy.id
  key     = "keda.yaml"
  content = local.rendered_keda
}

# deploy.sh Í∞Ä source ???òÍ≤ΩÎ≥Ä???åÏùº (apply ?úÏ†ê Í∞íÏúºÎ°??åÎçîÎß?
resource "aws_s3_object" "env_sh" {
  bucket  = aws_s3_bucket.deploy.id
  key     = "env.sh"
  content = <<-EOT
    export REGION="${data.aws_region.current.name}"
    export ECR_REPO="${aws_ecr_repository.app.repository_url}"
    export CLUSTER_NAME="${aws_eks_cluster.main.name}"
    export CLUSTER_ENDPOINT="${aws_eks_cluster.main.endpoint}"
    export KEDA_ROLE_ARN="${aws_iam_role.keda_irsa.arn}"
    export KARPENTER_ROLE_ARN="${aws_iam_role.karpenter_irsa.arn}"
  EOT
}

resource "aws_s3_object" "deploy_sh" {
  bucket = aws_s3_bucket.deploy.id
  key    = "deploy.sh"
  source = "${path.module}/deploy.sh"
  etag   = filemd5("${path.module}/deploy.sh")
}

# --- Bastion IAM Role (SSM + ECR push + EKS describe + S3 read) ---
resource "aws_iam_role" "bastion" {
  name = "skm-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "bastion_ecr" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy" "bastion" {
  name = "skm-bastion-policy"
  role = aws_iam_role.bastion.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.deploy.arn, "${aws_s3_bucket.deploy.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "skm-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Bastion ??kubectl/helm ?ºÎ°ú ?¥Îü¨?§ÌÑ∞Î•??úÏñ¥?????àÎèÑÎ°?EKS Admin access entry Î∂Ä??resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}

# Bastion SG (?∏Î∞î?¥Îìú Î∂àÌïÑ????SSM ?¨Ïö©, ?ÑÏõÉÎ∞îÏö¥???ÑÏ≤¥ ?àÏö©)
resource "aws_security_group" "bastion" {
  name        = "skm-bastion-sg"
  description = "skm bastion (SSM, egress only)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "skm-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  subnet_id                   = aws_subnet.pub_a.id
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
set -e
dnf install -y docker git jq unzip
systemctl enable --now docker

# aws cli v2
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && ./aws/install --update

# kubectl (EKS 1.35)
curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable-1.35.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Î∞∞Ìè¨ Î≤àÎì§ ?§Ïö¥Î°úÎìú
mkdir -p /opt/deploy
/usr/local/bin/aws s3 cp s3://${aws_s3_bucket.deploy.id}/ /opt/deploy/ --recursive --region ${data.aws_region.current.name}
chmod +x /opt/deploy/deploy.sh
echo "BASTION_READY" > /opt/deploy/.ready
EOF

  tags = { Name = "skm-bastion" }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_access_policy_association.creator,
    aws_eks_addon.coredns,
    aws_s3_object.app_py,
    aws_s3_object.dockerfile,
    aws_s3_object.requirements,
    aws_s3_object.m_karpenter,
    aws_s3_object.m_app,
    aws_s3_object.m_keda,
    aws_s3_object.env_sh,
    aws_s3_object.deploy_sh,
  ]
}

output "ecr_image" {
  value = local.ecr_image
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

# SSM ?ëÏÜç ??Î∞∞Ìè¨ ?§Ìñâ Î™ÖÎ†π ?àÎÇ¥
output "deploy_command" {
  value = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${data.aws_region.current.name}   # ?ëÏÜç ??  sudo bash /opt/deploy/deploy.sh"
}

# =====================================================================
# IAM user for the Jenkins server (Jenkins runs OUTSIDE AWS).
# Terraform creates the user + least-privilege policy.
# The ACCESS KEY is created manually by an admin (see README, Step 2)
# so the secret never ends up in Terraform state.
# =====================================================================

resource "aws_iam_user" "jenkins" {
  name = "${var.app_name}-jenkins"
}

data "aws_iam_policy_document" "jenkins" {
  # --- Terraform state (S3, incl. lock file) ---
  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.tfstate.arn]
  }
  statement {
    sid       = "TerraformStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # --- ECR: login + push/pull only this repository ---
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImageScanFindings",
      "ecr:ListTagsForResource",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # --- Infrastructure Terraform manages for the app ---
  # The VPC and subnets already exist; Terraform only reads them and
  # creates security groups and either a NAT gateway (+ route) or VPC endpoints.
  statement {
    sid = "AppInfrastructure"
    actions = [
      "ec2:Describe*",
      "ec2:*SecurityGroup*",
      "ec2:*VpcEndpoint*",
      "ec2:*NatGateway*",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:DisassociateAddress",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ecs:*",
      "elasticloadbalancing:*",
      "application-autoscaling:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }

  # --- IAM roles for the ECS tasks (only roles named <app_name>-*) ---
  statement {
    sid = "AppTaskRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.app_name}-*"]
  }
  statement {
    sid       = "PassTaskRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.app_name}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # --- AWS service-linked roles created automatically on first use ---
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_policy" "jenkins" {
  name   = "${var.app_name}-jenkins-deploy"
  policy = data.aws_iam_policy_document.jenkins.json
}

resource "aws_iam_user_policy_attachment" "jenkins" {
  user       = aws_iam_user.jenkins.name
  policy_arn = aws_iam_policy.jenkins.arn
}

# =====================================================================
# EXISTING network (not created or changed by Terraform - only read):
#   public subnets  -> load balancer
#   private subnets -> ECS tasks (no public IP)
# Terraform creates only the security groups (and, optionally,
# VPC endpoints so private tasks can reach ECR without a NAT gateway).
# =====================================================================

data "aws_subnet" "public" {
  for_each = toset(var.public_subnet_ids)
  id       = each.value
}

data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

# The VPC is taken from the first public subnet - no VPC ID needed in config
data "aws_vpc" "this" {
  id = data.aws_subnet.public[var.public_subnet_ids[0]].vpc_id
}

locals {
  vpc_id      = data.aws_vpc.this.id
  vpc_cidr    = data.aws_vpc.this.cidr_block
  public_azs  = toset([for s in data.aws_subnet.public : s.availability_zone])
  private_azs = toset([for s in data.aws_subnet.private : s.availability_zone])
}

# Fail early with a clear message if the subnets are not usable
check "subnets_in_two_azs" {
  assert {
    condition     = length(local.public_azs) >= 2 && length(local.private_azs) >= 2
    error_message = "Public and private subnets must each be in at least 2 different Availability Zones (load balancer + high availability)."
  }
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Internet to load balancer"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To tasks inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task-sg"
  description = "Load balancer to ECS tasks only"
  vpc_id      = local.vpc_id

  ingress {
    description     = "App port from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound (ECR, CloudWatch, external APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-task-sg" }
}

# =====================================================================
# OUTBOUND ACCESS FOR PRIVATE SUBNETS - pick ONE (see README Step 2b):
#   create_nat_gateway   = true -> NAT gateway (ECR + any internet API)
#   create_vpc_endpoints = true -> private endpoints (ECR/S3/Logs only)
# Both need private_route_table_ids.
# =====================================================================

check "outbound_access_configured" {
  assert {
    condition     = var.create_nat_gateway || var.create_vpc_endpoints
    error_message = "Neither create_nat_gateway nor create_vpc_endpoints is set. Ignore this ONLY if the private subnets already route to a NAT gateway - otherwise tasks cannot pull images from ECR."
  }
}

# ---------- Option A: NAT gateway ----------
resource "aws_eip" "nat" {
  count  = var.create_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  count         = var.create_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = var.public_subnet_ids[0] # lives in a PUBLIC subnet
  tags          = { Name = "${local.name}-nat" }

  lifecycle {
    precondition {
      condition     = length(var.private_route_table_ids) > 0
      error_message = "Set private_route_table_ids so the NAT route can be added (run scripts/check-network.sh)."
    }
  }
}

# Adds 0.0.0.0/0 -> NAT to the private route table(s). Nothing else in them is changed.
resource "aws_route" "private_nat" {
  for_each               = var.create_nat_gateway ? toset(var.private_route_table_ids) : toset([])
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# ---------- Option B: VPC endpoints ----------
resource "aws_security_group" "endpoints" {
  count       = var.create_vpc_endpoints ? 1 : 0
  name        = "${local.name}-vpce-sg"
  description = "HTTPS from inside the VPC to AWS service endpoints"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = { Name = "${local.name}-vpce-sg" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = var.create_vpc_endpoints ? toset(["ecr.api", "ecr.dkr", "logs"]) : toset([])
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.value}" }
}

# ECR stores image layers in S3 -> gateway endpoint (free)
resource "aws_vpc_endpoint" "s3" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
  tags              = { Name = "${local.name}-s3" }

  lifecycle {
    precondition {
      condition     = length(var.private_route_table_ids) > 0
      error_message = "Set private_route_table_ids for the S3 gateway endpoint (run scripts/check-network.sh)."
    }
  }
}

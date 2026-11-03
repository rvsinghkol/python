# Production settings. image_tag is NOT here - Jenkins passes it on every run.

aws_region    = "ap-south-2"
app_name      = "docker-remote"
environment   = "prod"
ecr_repo_name = "docker_remote"

# Capacity
cpu           = "1024" # 1 vCPU
memory        = "2048" # 2 GB
desired_count = 2
min_count     = 2
max_count     = 6
cpu_target    = 60

# Network - existing VPC 10.0.0.0/16
public_subnet_ids = [
  "subnet-07d6275970e1880a5", # Mynfintech-public-subnet1   10.0.1.0/24
  "subnet-0819c6fdba75bb607", # Myndfintech-public-subnet2  10.0.2.0/24
]

private_subnet_ids = [
  "subnet-03d64d86a8828a763", # Myndfintech-private-subnet   10.0.3.0/24
  "subnet-0da8fd6cf0022a865", # Myndfintech-subnet-private1  10.0.4.0/24
]

# Route table of the private subnets - get it from scripts/check-network.sh
# (VPC console -> Subnets -> private subnet -> "Route table" tab). List each ID once.
private_route_table_ids = [
  "rtb-REPLACE_ME",
]

# Your VPC has an Internet Gateway (igw-02c95d919709327c9) but NO NAT gateway.
# Choose ONE:
create_nat_gateway   = true  # A) NAT: tasks can pull from ECR AND call internet APIs
create_vpc_endpoints = false # B) endpoints: ECR/S3/Logs only, no internet

# Load balancer
health_check_path       = "/"
alb_deletion_protection = true
certificate_arn         = "" # set an ACM certificate ARN later to enable HTTPS

# Alerts - put your team's distribution list here, e.g. "devops-team@yourcompany.com"
alarm_email = ""

log_retention_days = 30

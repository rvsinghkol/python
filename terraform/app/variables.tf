# ---------- General ----------
variable "aws_region" {
  type    = string
  default = "ap-south-2"
}

variable "app_name" {
  description = "Must match app_name used in terraform/bootstrap"
  type        = string
  default     = "docker-remote"
}

variable "environment" {
  type    = string
  default = "prod"
}

# ---------- Image ----------
variable "ecr_repo_name" {
  type    = string
  default = "docker_remote"
}

variable "image_tag" {
  description = "ECR image tag to deploy. Passed by Jenkins (deploy = new tag, rollback = old tag)."
  type        = string

  validation {
    condition     = length(var.image_tag) > 0
    error_message = "image_tag must not be empty."
  }
}

# ---------- Network (existing VPC) ----------
variable "public_subnet_ids" {
  description = "Existing public subnets (route to Internet Gateway) for the load balancer - 2 different AZs"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Give at least 2 public subnets."
  }
}

variable "private_subnet_ids" {
  description = "Existing private subnets for the ECS tasks - 2 different AZs"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Give at least 2 private subnets."
  }
}

variable "private_route_table_ids" {
  description = "Route table(s) used by the private subnets (from scripts/check-network.sh). Same ID twice is fine - list it once."
  type        = list(string)
  default     = []
}

variable "create_nat_gateway" {
  description = "Create a NAT gateway and add 0.0.0.0/0 -> NAT to the private route tables"
  type        = bool
  default     = false
}

variable "create_vpc_endpoints" {
  description = "Create ECR/S3/Logs VPC endpoints instead of a NAT (no general internet access for tasks)"
  type        = bool
  default     = false
}

# ---------- Load balancer ----------
variable "certificate_arn" {
  description = "ACM certificate ARN. Leave empty for HTTP only; set it to enable HTTPS + redirect."
  type        = string
  default     = ""
}

variable "alb_deletion_protection" {
  type    = bool
  default = true
}

variable "health_check_path" {
  description = "Path the load balancer checks. Must return HTTP 200-399."
  type        = string
  default     = "/"
}

# ---------- Container / service ----------
variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  description = "Task CPU units (1024 = 1 vCPU)"
  type        = string
  default     = "1024"
}

variable "memory" {
  description = "Task memory in MiB"
  type        = string
  default     = "2048"
}

variable "desired_count" {
  description = "Tasks to start with. Autoscaling manages it afterwards."
  type        = number
  default     = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 6
}

variable "cpu_target" {
  description = "Autoscaling keeps average CPU around this %"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ---------- Monitoring ----------
variable "alarm_email" {
  description = "Email for CloudWatch alarms (must confirm the subscription email). Empty = no email."
  type        = string
  default     = ""
}

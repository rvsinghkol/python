variable "aws_region" {
  type    = string
  default = "ap-south-2"
}

variable "app_name" {
  description = "Must match app_name in terraform/app."
  type        = string
  default     = "docker-remote"
}

variable "ecr_repo_name" {
  type    = string
  default = "docker_remote"
}

variable "ecr_keep_images" {
  description = "How many images to keep in ECR. This is also how far back you can roll back."
  type        = number
  default     = 5
}

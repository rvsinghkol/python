terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Bucket comes from the bootstrap output "state_bucket".
  # (Backend blocks cannot use variables, so it is written here directly.)
  backend "s3" {
    bucket       = "docker-remote-tfstate-707479681461"
    key          = "app/prod/terraform.tfstate"
    region       = "ap-south-2"
    encrypt      = true
    use_lockfile = true # stops two builds changing prod at the same time
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name = "${var.app_name}-${var.environment}" # e.g. docker-remote-prod
}

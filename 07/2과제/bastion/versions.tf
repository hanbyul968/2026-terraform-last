terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  # 07 루트 module4(EKS/SQS) 리전과 동일 (us-west-2 Oregon).
  # Bastion이 이 리전에서 docker build/push + kubectl/helm 을 수행한다.
  region = var.region

  default_tags {
    tags = {
      Project = "wsc-2026-task2-07-bastion"
      Player  = var.player_id
    }
  }
}

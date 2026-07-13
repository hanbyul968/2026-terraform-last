terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.60" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "wsc-2026-task2-02-bastion"
      Player  = var.player_id
    }
  }
}

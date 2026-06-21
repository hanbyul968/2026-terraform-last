# =============================================================================
# 멀티 리전 Provider
#  - 각 모듈은 문제에서 지정한 리전에서만 수행 (모듈 간 리소스 공유 금지)
#    Module1 NoSQL    : ap-northeast-2 (서울)   -> aws.seoul (default)
#    Module2 CDN      : us-east-1      (버지니아) -> aws.use1
#    Module3 Workflow : ap-southeast-1 (싱가포르) -> aws.sg
#    Module4 RDS      : ap-northeast-3 (오사카)   -> aws.osaka
# =============================================================================

# 기본 provider = 서울 (Module1)
provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      TeamId  = var.team_id
    }
  }
}

provider "aws" {
  alias  = "seoul"
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      TeamId  = var.team_id
    }
  }
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      TeamId  = var.team_id
    }
  }
}

provider "aws" {
  alias  = "sg"
  region = "ap-southeast-1"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      TeamId  = var.team_id
    }
  }
}

provider "aws" {
  alias  = "osaka"
  region = "ap-northeast-3"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      TeamId  = var.team_id
    }
  }
}

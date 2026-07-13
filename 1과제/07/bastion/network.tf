# =============================================================================
# 1단계(bastion 스테이지)가 "진짜" VPC(unicorn-vpc)를 생성한다.
#   - 기존에는 root(main.tf)가 module.VPC 로 VPC 를 만들고, bastion 은 별도
#     throwaway VPC(10.250.0.0/16)에 떠 있었다. 그 결과 bastion 이 채점 대상
#     VPC 밖에 있어 EKS/클러스터와 같은 네트워크가 아니었다.
#   - 01 모델대로, 네트워크(VPC/서브넷/IGW/NAT/RT/FlowLogs/VPCE)를 이 스테이지가
#     소유하고, bastion 을 진짜 퍼블릭 서브넷(unicorn-subnet-pub-a)에 배치한다.
#   - root(2단계, bastion 안에서 apply)는 이 VPC 를 이름(tag:Name)으로 data 조회한다.
#
# ※ 파라미터는 기존 root main.tf 의 module "VPC" 호출값과 동일하게 유지한다.
# =============================================================================
module "VPC" {
  source               = "../modules/VPC"
  vpc_name             = "unicorn-vpc"
  vpc_cidr             = "10.97.0.0/16"
  public_subnets_cidr  = ["10.97.0.0/24", "10.97.1.0/24", "10.97.2.0/24"]
  private_subnets_cidr = ["10.97.10.0/24", "10.97.11.0/24", "10.97.12.0/24"]
  availability_zones   = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnet_names  = ["unicorn-subnet-pub-a", "unicorn-subnet-pub-b", "unicorn-subnet-pub-c"]
  private_subnet_names = ["unicorn-subnet-priv-a", "unicorn-subnet-priv-b", "unicorn-subnet-priv-c"]
  igw_name             = "unicorn-igw"
  nat_eip_names        = ["unicorn-eip-nat-a", "unicorn-eip-nat-b", "unicorn-eip-nat-c"]
  nat_gw_names         = ["unicorn-nat-a", "unicorn-nat-b", "unicorn-nat-c"]
  public_rt_name       = "unicorn-rt-pub"
  private_rt_names     = ["unicorn-rt-priv-a", "unicorn-rt-priv-b", "unicorn-rt-priv-c"]
  flow_log_name        = "unicorn-flow-log"
}

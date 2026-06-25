# 사전준비

대회 환경 세팅용 설치 명령어 모음.

---

## 1. Windows 로컬 (PowerShell 관리자 권한)

### Docker Desktop
```powershell
winget install -e --id Docker.DockerDesktop
```
> choco 사용 시: `choco install docker-desktop -y`

### Terraform
```powershell
winget install -e --id Hashicorp.Terraform
```
> choco 사용 시: `choco install terraform -y`

### AWS CLI
```powershell
winget install -e --id Amazon.AWSCLI
```
> choco 사용 시: `choco install awscli -y`

### 한 번에 설치 (winget)
```powershell
winget install -e --id Docker.DockerDesktop; winget install -e --id Hashicorp.Terraform; winget install -e --id Amazon.AWSCLI
```

### 한 번에 설치 (choco)
```powershell
choco install docker-desktop terraform awscli -y
```

> 설치 후 새 터미널을 열어야 PATH가 적용됩니다. 확인: `terraform -version`, `aws --version`, `docker --version`

---

## 2. AWS CloudShell (Amazon Linux 2023) — ⚠️ 비권장

CloudShell은 홈 용량이 **1GB**라 provider(약 700MB)+state 저장 중
`no space left on device`로 apply가 실패합니다. **로컬(Windows)에서 실행하세요.**

(참고용) CloudShell Terraform 설치 한 줄:
```bash
sudo yum install -y yum-utils && sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo && sudo yum -y install terraform
```

---

## 3. 기본 VPC(Default VPC)

각 모듈은 **Default VPC**를 사용합니다. 기본 VPC가 없어도 terraform이
`aws_default_vpc` 리소스로 **자동 생성/채택**하므로 별도 작업이 필요 없습니다.

---

## 4. 배포 순서 요약 (로컬 Windows / Git Bash)

provisioner가 bash/openssl/aws/pip 기반이라 **Git Bash 터미널**에서 실행.

```bash
aws configure                                   # 자격증명 1회 설정
cd ~ && git clone https://github.com/hnmly/2026-terraform.git
cd ~/2026-terraform/05/2과제
terraform init
terraform apply -var pin=<비번호> -var alarm_email=<이메일>
```
> 상세/트러블슈팅은 [05/2과제/README.md](../05/2과제/README.md) 참고.

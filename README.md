# 🏆 제61회 전국기능경기대회 Cloud Computing 과제 솔루션

제61회 전국기능경기대회 클라우드 컴퓨팅 직종 테라폼(Terraform) 소스 저장소.
연습 회차 중 대표 과제만 추려 **`1과제/`**, **`2과제/`** 아래에 회차 번호로 정리했습니다.

---

## 📂 디렉토리 구조

```
2026-terraform/
├── README.md
├── 1과제/                # EKS/컨테이너 중심 (단일 root + bastion)
│   ├── 02/  ├── 03/  ├── 06/  └── 07/
├── 2과제/                # 멀티모듈(리전·state 분리). 02 는 module1~3(Cloud Event Handling 삭제 반영)
│   ├── 02/  ├── 07/  └── 08/
├── 3과제/                # System Operation (별도 repo: hnmly/2026-0621-jaemu-task3)
├── 솔루션/               # AWS 콘솔 클릭 솔루션 가이드
├── 부하/                 # 부하 테스트 & 채점 시뮬레이터 웹 도구
├── 사전준비/ · import/    # 사전 세팅 / terraform import 참고
└── _pdfimg/ · _scoreimg/  # 과제지·채점표 이미지
```

> 각 폴더의 **`README.md`** 에 모듈별 리전·비번호 치환 위치·수동 단계·로컬 vs bastion apply 구분·대회 30% 변경 대응이 정리돼 있습니다.

---

## 🚀 새 컴퓨터 초기 세팅 (Fresh Windows PC)

배포는 bastion(Linux)에서 하므로 **로컬엔 Docker·kubectl·helm 불필요**.

```powershell
winget install -e --id Hashicorp.Terraform
winget install -e --id Amazon.AWSCLI
winget install -e --id Amazon.SessionManagerPlugin   # SSM start-session ★필수
winget install -e --id Git.Git
```
> 설치 후 **PowerShell 새 창**을 열어 PATH 갱신.

```powershell
terraform -version ; aws --version ; session-manager-plugin ; git --version

aws configure          # Access Key / Secret / region ap-northeast-2 / json
aws sts get-caller-identity

cd C:\Users\competitor
git clone https://github.com/hanbyul968/2026-terraform-last.git
cd 2026-terraform-last
```

> 🔓 **자격 증명 없이 clone**: 이 저장소는 **Public** 이고 Git LFS·서브모듈을 쓰지 않으므로
> 위 **HTTPS** 주소는 GitHub 로그인/토큰/SSH 키 없이 그대로 clone 된다.
>
> `git@github.com:...` (SSH) 주소를 쓰면 SSH 키가 없는 새 PC 에서
> `git@github.com: Permission denied (publickey). fatal: Could not read from remote repository.` 가 발생한다.
> **반드시 `https://` 주소를 사용**하고, 이미 SSH 로 설정된 clone 이면 remote 를 바꾼다.
> ```powershell
> git remote set-url origin https://github.com/hanbyul968/2026-terraform-last.git
> git remote -v      # origin https://github.com/... 확인
> ```
> 읽기 전용이면 인증이 필요 없고, **push 할 때만** GitHub 계정(브라우저 로그인 또는 PAT)이 필요하다.

> ⚠️ **이 대회 계정엔 default VPC 가 없습니다.** default VPC 를 쓰는 bastion 구성은 `Error: no matching EC2 VPC found` 로 실패하므로,
> 해당 bastion 의 `data "aws_vpc" "default"` / `data "aws_subnets" "default"` 를 전용 VPC(예: `10.250.0.0/16` + public subnet + IGW + route)로 교체해야 합니다. (아래 ⚠️ 표시 폴더)

---

## 공통 2단계 패턴

```
[로컬 Windows PowerShell]                 [Bastion (Amazon Linux)]
  cd <폴더>\bastion
  terraform init && apply   ──SSM/SSH──▶  bash /opt/task1/run.sh   (1과제)
  (bastion 생성)                            bash /opt/task2/deploy.sh (2과제)
        │
        ▼ (채점 후)
  cd bastion; terraform destroy  ◀── bastion 만 제거, 채점 대상은 별도 destroy
```

- 로컬에선 **bastion 만 apply**. 채점 대상 인프라는 **bastion 안에서** apply (루트 구성이 bash·docker·kubectl 의존 → Windows 직접 apply 불가).
- 접속: SSM 은 `terraform output -raw ssm_connect_command` 출력 명령 실행.
- EKS 포함 과제는 apply 에 **20~30분**.

---

## 1과제 Apply (단일 root + bastion)

| 폴더 | 원본 | 1단계(로컬) | 접속 | 2단계(bastion) | 비고 |
|---|---|---|---|---|---|
| **02** ⚠️ | 구 02/1과제 | `1과제\02\bastion` apply | SSM | `bash /opt/task1/run.sh` | bastion default-VPC 수정 필요 |
| **03** ⚠️ | 구 03/1과제 | `1과제\03\bastion` apply | SSM | `bash /opt/task1/run.sh` | EKS private 전환 / 구 bastion.tf 는 `.OLD-in-main` |
| **06** ⚠️ | 구 05/1과제 | `1과제\06\bastion` apply | SSM | `bash /opt/task1/run.sh` | EKS + k8s (`manifest/apply.sh`) |
| **07** ⚠️ | 구 06/1과제 | `1과제\07\bastion` apply | SSM | `bash /opt/task1/run.sh` | k8s 는 `manifest/apply.sh` |

예시(02):
```powershell
cd C:\Users\competitor\2026-terraform\1과제\02\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # → aws ssm start-session --target i-xxxx ...
```
```bash
# bastion 접속 후
until [ -f /opt/task1/READY ]; do sleep 5; done
bash /opt/task1/run.sh        # docker build/push + EKS + helm (+ EKS private 전환)
```

---

## 2과제 Apply (멀티모듈)

| 폴더 | 원본 | 1단계(로컬) | 접속 | 2단계(bastion) | 비고 |
|---|---|---|---|---|---|
| **02** ⚠️ | 구 02/2과제 | `2과제\02\bastion` apply | SSM | `BIBUNHO=102 bash /opt/task2/deploy.sh` | Workflow / Real-time Analytics / MSK (module1~3, 비번호 102) |
| **07** ⚠️ | 구 06/2과제 | `2과제\07\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | NoSQL / CDN / EKS / O11y (CloudShell EKS access entry 필요, README 참고) |
| **08** | 구 07/2과제 | `2과제\08\bastion` apply | SSM | `bash /opt/task2/run.sh` (= `terraform apply`) | 단일 root, in-module4 bastion 이 k8s 자동 구성 |

예시(02):
```powershell
cd C:\Users\competitor\2026-terraform-last\2과제\02\bastion
terraform init; terraform apply -auto-approve
terraform output -raw ssm_connect_command
```
```bash
until [ -f /opt/task2/READY ]; do sleep 5; done
BIBUNHO=102 bash /opt/task2/deploy.sh   # module1(Workflow)→module2(Analytics)→module3(MSK)
number=102 bash /opt/task2/mark1.sh     # 채점표 기준 자기검증 (mark2.sh / mark3.sh 도 동일)
BIBUNHO=102 bash /opt/task2/cleanup.sh  # 채점 전 module1 S3/DynamoDB 클렌징 (필수)
```

### 🟢 로컬 apply 가능 모듈 (VPC 불필요)

순수 서버리스(Lambda·API GW·DynamoDB·S3·EventBridge·CloudFront) 모듈은 **로컬 Windows 에서 바로 apply**. VPC/EKS/EC2/MSK 필요한 모듈만 bastion.

| 폴더 | 🟢 로컬 apply (VPC 없음) | 🔵 bastion apply (VPC 필요) |
|---|---|---|
| **02** | module1 Score(ap-ne-2), module3 Event/Config | module2 Flink-EC2, module4 MSK |
| **07** | module1 NoSQL, module2 CDN Function | module3 EKS Scaling, module4 Container Logging |
| **08** | 4개 모듈 전부 로컬 apply(단일 root) | module4 in-VPC bastion 이 k8s 자동 |

---

## 콘솔 솔루션 (테라폼 없이)

`솔루션/` 아래에 **AWS 콘솔 클릭만으로** 구성하는 단계별 가이드가 있습니다.
- 예: [`솔루션/09/2과제`](솔루션/09/2과제/README.md) — EKS Scaling / Container Logging / MSK / REST API 4모듈 콘솔 절차 + 자주 나는 오류.

---

## 채점 (Grading)

- 채점 스크립트는 네트워크 공유의 각 과제 `채점기준표&채점스크립트` 에 있습니다.
- 보통 **CloudShell** 또는 **bastion** 에서 실행. EKS 가 private 인 과제는 **bastion 또는 VPC 내부(CloudShell VPC 환경)** 에서 `kubectl` 채점 필요.
- EKS 가 bastion 역할로 생성된 경우, **CloudShell/채점 principal 을 클러스터 access entry 에 등록**해야 kubectl 채점이 됩니다(해당 폴더 README 참고).

## Destroy (정리)

```powershell
# 1) bastion 안에서 채점 대상 먼저 destroy
#    - 1과제: cd /opt/task1 && terraform destroy -auto-approve
#      (EKS private 로 닫았으면 destroy 전 public 재오픈:
#       aws eks update-cluster-config --name <cluster> --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true)
#    - 2과제: 각 module 디렉터리에서 terraform destroy (deploy 역순)
# 2) 로컬에서 bastion 제거
cd <폴더>\bastion ; terraform destroy -auto-approve
```

> ⚠️ 비용 주의: EKS·NAT·ALB·CloudFront·MSK·Aurora 등은 시간당 과금. 테스트 후 반드시 destroy.

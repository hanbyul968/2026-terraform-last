# 🏆 제61회 전국기능경기대회 Cloud Computing 과제 솔루션

본 리포지토리는 제61회 전국기능경기대회 클라우드 컴퓨팅 직종의 테라폼(Terraform) 소스 코드 저장소입니다. 마이스터넷 공식 과제 대비 중복 항목(기존 2번, 4번)을 통합 및 최적화하고, 4번 과제를 완전히 제거한 후 이후 번호를 하나씩 차감하여 총 9개의 과제 폴더(`001`~`009`)로 재구성하였습니다.

---

## 📊 과제 매핑 정보

실제 마이스터넷 공지 과제(10개)에서 **기존 2번과 4번의 아키텍처 중복을 제거(4번 삭제)**하고, Task 05번 과제부터 번호를 하나씩 차감(`-1`)하여 저장소 폴더 구조와 직관적으로 매칭되도록 최적화했습니다.

* **Task 01** ➡️ `01` 폴더
* **Task 02 / 04 (중복 통합)** ➡️ `002` 폴더
* **Task 03** ➡️ `03` 폴더
* **Task 05 (번호 차감)** ➡️ `04` 폴더
* **Task 06 (번호 차감)** ➡️ `05` 폴더
* **Task 07 (번호 차감)** ➡️ `06` 폴더
* **Task 08 (번호 차감)** ➡️ `07` 폴더
* **Task 09 (번호 차감)** ➡️ `08` 폴더
* **Task 10 (번호 차감)** ➡️ `09` 폴더

---

## 📂 디렉토리 구조 (Directory Structure)

각 과제 폴더 내부(예시: `03` 폴더)는 아래와 같이 **1과제**와 **2과제** 폴더로 분리되어 있으며, 과제 유형에 맞게 각각 안내 문서를 작성해야 합니다. 또한, 인프라의 변경사항이 발생하는 경우 루트의 `fix.md`에 상세히 기록합니다.

```directory
.
├── README.md                # 📄 프로젝트 메인 가이드 문서
├── fix.md                   # 📄 테라폼 인프라 변경사항 안내 및 기록
├── 1과제/
│   └─ README.md             # 📄 1과제 테라폼 사용 방법 안내
└── 2과제/
    ├─module1/
    │   └─ README.md         # 📄 module1 테라폼 사용 방법 안내
    ├─module2/
    │   └─ README.md         # 📄 module2 테라폼 사용 방법 안내
    ├─module3/
    │   └─ README.md         # 📄 module3 테라폼 사용 방법 안내
    └─module4/
        └─ README.md         # 📄 module4 테라폼 사용 방법 안내


---

# 🚀 전체 Apply 가이드 (01~09 / 1과제·2과제)

## 0. 사전 준비 (로컬 Windows PowerShell)

```powershell
winget install -e --id Hashicorp.Terraform
winget install -e --id Amazon.AWSCLI
winget install -e --id Amazon.SessionManagerPlugin   # SSM 접속용
aws configure        # Access Key / Secret / region=ap-northeast-2
aws sts get-caller-identity   # 자격증명 확인
```

> ⚠️ **이 대회 계정에는 default VPC 가 없습니다.**
> SSM bastion 들은 기본적으로 default VPC 를 쓰도록 작성돼 있어 그대로면 `Error: no matching EC2 VPC found` 로 apply 가 실패합니다.
> **01/1과제 bastion 은 자체 VPC 생성 방식으로 수정 완료**. 나머지 bastion(아래 ⚠️ 표시)은 동일하게 `bastion/main.tf` 의
> `data "aws_vpc" "default"`/`data "aws_subnets" "default"` 를 전용 VPC(예: `10.250.0.0/16` + public subnet + IGW + route)로 교체해야 합니다.

## 공통 2단계 패턴

```
[로컬 Windows PowerShell]                 [Bastion (Amazon Linux)]
  cd <폴더>\bastion (또는 bootstrap)
  terraform init && apply        ──SSM/SSH──▶   bash /opt/task1/run.sh   (1과제)
  (bastion 생성)                                 bash /opt/task2/deploy.sh (2과제)
        │                                        또는 ./apply.sh / setup.sh
        ▼ (채점 후)
  cd bastion; terraform destroy   ◀── bastion 만 제거, 채점 대상은 별도 destroy
```

- **로컬에서는 bastion(또는 bootstrap)만 apply** 합니다. 채점 대상 인프라는 **bastion(Linux) 안에서** apply 합니다
  (루트 구성이 `/bin/bash` provisioner·docker build·kubectl 에 의존하므로 Windows 직접 apply 불가).
- 접속: SSM 방식은 `terraform output -raw ssm_connect_command` 출력 명령 실행. SSH 방식(07/1과제)은 `ssh -i bastion-key.pem ...`.
- EKS 클러스터 포함 과제는 apply 에 **20~30분** 소요됩니다.

---

## 1과제 Apply

| 폴더 | 1단계(로컬) | 접속 | 2단계(bastion에서) | 비고 |
|---|---|---|---|---|
| **01** | `01\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | bastion 자체VPC ✅ / 끝에 EKS private 전환(finalize) |
| **02** ⚠️ | `02\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | bastion default-VPC 수정 필요 |
| **03** ⚠️ | `03\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | EKS private 전환 / 구 bastion.tf 는 `.OLD-in-main` |
| **04** ⚠️ | `04\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | EKS private 전환 / 루트 in-VPC bastion 유지 |
| **05** ⚠️ | `05\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | |
| **06** ⚠️ | `06\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | k8s 는 `manifest/apply.sh` |
| **07** | `07\1과제\bootstrap` apply | SSH (`bastion-key.pem`) | `./apply.sh` | bootstrap=자체VPC, main=ECS |
| **08** ⚠️ | `08\1과제\bastion` apply | SSM | `bash /opt/task1/run.sh` | bastion default-VPC 수정 필요 |
| **09** | `09\1과제\bootstrap` apply | SSH (`worldpay2026!`) | `cd ~/project/app && terraform apply` → `manifest/setup.sh` | Full-private EKS |

예시(01):
```powershell
cd C:\Users\competitor\2026-terraform\01\1과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # → aws ssm start-session --target i-xxxx --region ap-northeast-2
```
```bash
# bastion 접속 후
until [ -f /opt/task1/READY ]; do sleep 5; done
bash /opt/task1/run.sh        # docker build/push + EKS + helm + (finalize: EKS private)
```

---

## 2과제 Apply

대부분 멀티모듈(module1~4, 각자 리전·state) → bastion 에서 `deploy.sh` 가 순서대로 apply.

| 폴더 | 1단계(로컬) | 접속 | 2단계(bastion에서) | 비고 |
|---|---|---|---|---|
| **01** ⚠️ | `01\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | module-1..4 (REST/RDS/Workflow/VPN) |
| **02** ⚠️ | `02\2과제\bastion` apply | SSM | `BIBUNHO=<비번호> bash /opt/task2/deploy.sh` | Workflow/Kinesis-Flink/Event/MSK |
| **03** ⚠️ | `03\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | CDN/Keycloak/Logging/Workflow |
| **04** ⚠️ | `04\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | EKS Scaling/Lattice/Logging/REST |
| **05** ⚠️ | `05\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | Flink/CDN/Event/Keycloak |
| **06** ⚠️ | `06\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | NoSQL/CDN/EKS/O11y (+CloudShell EKS access entry, README 참고) |
| **07** | `07\2과제\bastion` apply | SSM | `bash /opt/task2/run.sh` (= `terraform apply`) | 단일 root, in-module4 bastion 가 k8s 자동 |
| **08** ⚠️ | `08\2과제\bastion` apply | SSM | `terraform apply -var="team_id=<비번호>"` | NoSQL/CDN/Workflow/RDS |
| **09** ⚠️ | `09\2과제\bastion` apply | SSM | `bash /opt/task2/deploy.sh` | EKS Scaling/Lattice/Logging/REST |

예시(04):
```powershell
cd C:\Users\competitor\2026-terraform\04\2과제\bastion
terraform init; terraform apply -auto-approve
terraform output -raw ssm_connect_command
```
```bash
until [ -f /opt/task2/READY ]; do sleep 5; done
bash /opt/task2/deploy.sh     # module1→module4 순차 apply + EKS/KEDA/Karpenter/Loki/Grafana
```

> 각 폴더의 **`README.md`** 에 모듈별 리전·비번호 치환 위치·수동 단계(SNS 구독, MSK 토픽, Keycloak Realm, Flink 노트북 등)·대회 30% 변경 대응 가이드가 정리돼 있습니다.

---

## 채점 (Grading)

- 채점 스크립트는 네트워크 공유의 각 과제 `채점기준표&채점스크립트\채점스크립트` (또는 `채점지`) 에 있습니다.
- 보통 **CloudShell** 또는 **bastion** 에서 실행합니다. EKS 가 private 인 과제(01/03/04 1과제, 09)는 **bastion 또는 VPC 내부**에서 `kubectl` 채점이 필요합니다.
- 2과제 06 등 EKS 가 bastion 역할로 생성된 경우, **CloudShell principal 을 클러스터 access entry 에 등록**해야 kubectl 채점이 됩니다(해당 폴더 README 참고).

## Destroy (정리)

```powershell
# 1) bastion 안에서 채점 대상(main/모듈) 먼저 destroy
#    - 1과제: cd /opt/task1 && terraform destroy -auto-approve
#      (EKS private 로 닫았으면 destroy 전 public 재오픈 필요:
#       aws eks update-cluster-config --name <cluster> --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true)
#    - 2과제: 각 module 디렉터리에서 terraform destroy (deploy 역순)
# 2) 로컬에서 bastion 제거
cd <폴더>\bastion ; terraform destroy -auto-approve
```

> ⚠️ 비용 주의: EKS·NAT·ALB·CloudFront·MSK·Aurora 등은 시간당 과금됩니다. 테스트 후 반드시 destroy 하세요.

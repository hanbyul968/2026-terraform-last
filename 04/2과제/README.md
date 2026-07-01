# 2과제 (04) — Small Challenge

제61회 인천기능경기대회 클라우드컴퓨팅 **제2과제**. 4개 모듈(EKS Scaling / VPC Lattice / Container Logging / REST API).

두 단계 배포:
1. **로컬(Windows PowerShell)**: `bastion/` 을 apply → SSM 전용 Bastion(Linux) 이 뜨고 2과제 코드 전체를 받아 `deploy.sh` 를 준비한다. **VPC 가 필요 없는 module4(REST API)** 는 로컬에서 바로 apply 해도 전부 생성된다.
2. **Bastion(Linux)**: `bash /opt/task2/deploy.sh <비번호>` — module1→k8s→module2→module3→module4 를 순서대로 apply.

| 모듈 | 내용 | 리전 | apply 위치 |
|------|------|------|-----------|
| module1 (+k8s) | EKS Scaling (KEDA + Karpenter, SQS) | ap-northeast-2 | **Bastion** (EKS/helm/kubectl) |
| module2 | VPC Lattice (Hub/Spoke, header+weighted routing) | ap-southeast-1 | Bastion 권장 (Linux 종속 없음 → 로컬도 가능) |
| module3 | Container logging (EKS + Loki/Grafana, EC2 docker flask + Fluent Bit) | ap-northeast-1 | **Bastion** (EKS/helm/docker) |
| module4 | REST API (API Gateway + Lambda py3.14 + DynamoDB) | us-east-1 | **로컬 가능** (순수 서버리스, VPC 없음) |

---

## 1) 로컬 — Bastion 생성 + module4(로컬)

```powershell
# Bastion
cd C:\Users\competitor\2026-terraform\04\2과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command    # 접속 명령 출력

# (선택) VPC 없는 module4 는 로컬에서 바로 생성 가능
cd ..\module4
terraform init
terraform apply -auto-approve
```

## 2) Bastion 접속 (SSM) 후 전체 배포

```powershell
aws ssm start-session --target <bastion-id> --region ap-northeast-2
```
```bash
until [ -f /opt/task2/READY ]; do sleep 5; done
bash /opt/task2/deploy.sh <비번호>     # 예: bash /opt/task2/deploy.sh 07
```

---

## 모듈별 상세 (리전 / 주요 리소스)

### module1 — EKS Scaling (ap-northeast-2)
- VPC `wsc-scaling-vpc` 10.11.0.0/16, 서브넷 `wsc-scaling-pub-sn-a/c`(10.11.0.0/24, 10.11.1.0/24), `wsc-scaling-priv-sn-a/c`(10.11.10.0/24, 10.11.11.0/24) — **채점표(1-1-A) 기준 이름 `pub-sn`/`priv-sn`** (문제지는 `sn-pub`/`sn-priv` 로 표기 → ⚠️ 아래 불일치 참고)
- EKS `wsc-scaling-cluster` **버전 1.35**(채점표 1-2-A)
- Bastion `wsc-scaling-bastion`(t3.medium, Public-A, **EIP 로 재시작 후 IP 고정**, AdministratorAccess)
- SQS `wsc-scaling-sqs`
- Managed NodeGroup `wsc-scaling-node`(t3.medium, min 2 / max 10, labels dedicated=scaling)
- `module1/k8s`(helm+kubectl provider): KEDA(ns keda), Karpenter(kube-system), Namespace `wsc-scaling`, Deployment `wsc-scaling-deploy`(busybox:latest, cpu 250m/500m, mem 256Mi/512Mi), ScaledObject `wsc-scaling-scaledobject`(SQS, pollingInterval=30, queueLength=5, minReplica=2), Karpenter EC2NodeClass/NodePool

### module2 — VPC Lattice (ap-southeast-1)
- Hub VPC `wsc-hub-vpc` 10.0.0.0/16 (pub-a/c), Spoke VPC `wsc-spoke-vpc` 192.168.0.0/16 (pub-a/c, priv-a/c)
- Bastion `wsc-hub-bastion`(t3.small, Hub Public-A, **SSH 비밀번호 `Skill53##`**, EIP)
- App `wsc-spoke-app-v1` / `wsc-spoke-app-v2`(t3.medium, Spoke Private-A) — 지급 flask 앱(`app/version1.py`, `app/version2.py`, TCP 8080)을 그대로 기동
- Internal ALB `wsc-spoke-app-alb`(HTTP 80): `/healthcheck`→403 "Restrict access to api", `/version`→가중치 v1 90%/v2 10%, 그 외→404 "Not Found". TG `wsc-spoke-v1-tg`/`wsc-spoke-v2-tg`
- VPC Lattice: Service Network `wsc-app-service-network`, Service `wsc-app-service`. Header `version:v1`→v1-tg(priority 10, weight 100), `version:v2`→v2-tg(priority 20, weight 100). 헤더 없으면 weighted 90/10 (헤더 우선)

### module3 — Container Logging (ap-northeast-1)
- VPC **`wsc-log-vpc`** 10.3.0.0/16 (채점표 3-1-A 필터 기준; 문제지 표기는 `wsc-logging-vpc`) — 서브넷 `wsc-logging-sn-pub-a`(10.3.0.0/24), `wsc-logging-sn-priv-a`(10.3.1.0/24), `wsc-logging-sn-pub-c`(10.3.2.0/24), `wsc-logging-sn-priv-c`(10.3.3.0/24) — **채점표 CIDR pairing** (EC2=Public, EKS 노드=Private)
- EKS `wsc-logging-cluster`(v1.35), NodeGroup `wsc-logging-ng`(t3.medium/AL2023, min 2 / **max 4**), EBS CSI addon(Loki PVC 용)
- App EC2 **`wsc-log-app-bastion`**(t3.small/AL2023; 채점표 3-3-A 필터 기준, 문제지 표기는 `wsc-logging-app-bastion`): **부팅 시 `ec2-bootstrap.sh` 자동 실행** →
  - 지급 배포파일(`app/app.py`,`Dockerfile`,`requirements.txt`)로 docker 이미지 빌드 → 컨테이너 `wsc-log-app`(TCP 5000, `--restart always`, json-file 로깅)
  - `setup.sh`: AWS LB Controller 설치 → Loki(SingleBinary, filesystem PVC 10Gi, NLB:3100, ns wsc-logging) + Grafana(NLB, Loki datasource, 대시보드 "WSC2026 Container Logs" 4패널, refresh 5s) 배포 → Loki NLB DNS 를 SSM `/wsc/module3/loki-endpoint` 에 기록
  - Fluent Bit(host, systemd): docker json 로그 감시 → `record_modifier` 로 `namespace=wsc-app-log` 추가 → Loki NLB 전송 (Time_Format `%Y-%m-%dT%H:%M:%S.%L`, Asia/Seoul)
- 배포 아티팩트는 S3 `wsc-logging-artifacts-<account>` 로 배포됨

### module4 — REST API (us-east-1) — **로컬 apply 가능**
- API Gateway(REST) `wsc-rest-api`, stage `prod`, API Key `wsc-rest-api-key`(+Usage Plan)
- `POST /v1/user`(API Key 필수, body validation) / `GET /v1/user`(API Key 필수, querystring name·age 필수) / `GET /v1/healthcheck`(MOCK → `{"status":"ok"}`, Lambda 미개발)
- Lambda `wsc-rest-function`(Python 3.14, `lambda/handler.py` 그대로): Conditional Write(중복→"User already exists"), Query 전용 조회(없음→"User not found"), Stack Trace 비노출, boto3 전역 재사용
- DynamoDB `wsc-rest-table`(**PK `name`(S) 단일 파티션 키**, `age`·`country` 는 일반 속성, PAY_PER_REQUEST) — 채점표 4-3-A 가 name 키만으로 delete-item 하므로 SK 없음

---

## 비번호(선수번호) 치환 지점
- **module3 Grafana admin**: `deploy.sh <비번호>` 인자로 전달 → `wsc2026-admin-<비번호>` / `admin<비번호>!` 로 자동 반영(module3 `competitor_number` 변수). 로컬에서 module3 를 직접 apply 하면 `-var="competitor_number=<비번호>"` 를 붙인다.
- **bastion/module 리소스명**: 문제 고정 이름 사용(비번호 치환 불필요). `bastion` 의 `player_id` 변수(기본 wsc)는 부트스트랩 버킷/리소스 접두어 식별용이므로 원하면 본인 번호로 바꿔도 무방.
- module3 `manifest/grafana-values.yaml` 는 참고용(실행 경로는 `setup.sh`). 수동 배포 시 adminUser/adminPassword 를 본인 번호로 치환.

## 수동/후속 단계
- module3: app EC2 자동 구성 확인 — SSM 접속 후 `cat /opt/ec2_ready.txt`, `cat /tmp/m3_setup_done.txt`, `kubectl get svc -n wsc-logging`. Loki/Grafana NLB 주소는 `kubectl get svc -n wsc-logging` 로 확인.
- module2: Lattice Service 의 DNS(`terraform output lattice_service_dns`)로 Hub bastion 에서 `curl -H "version: v1" http://<dns>/version` 테스트.
- module4(로컬 apply 시): `terraform output invoke_url`, API Key 값은 `aws apigateway get-api-key --api-key <id> --include-value` 로 확인 후 `x-api-key` 헤더로 호출.

## 검증 상태 (terraform init -backend=false + validate)
- bastion / module1 / module1/k8s / module2 / module3 / module4 — **모두 "Success! The configuration is valid."**
- 실제 apply(EKS/KEDA/Karpenter/Lattice/Loki/Grafana)는 대회 환경에서 1회 수행 필요.

---

## 🧹 Bastion 네트워크 & 삭제 순서
- **Bastion 전용 VPC**: `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW (이 계정엔 default VPC 없음). 접속은 SSM 아웃바운드 443만 사용.
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`).
- **삭제**: 채점 대상(module1~4)은 Bastion 안에서 각 폴더 `terraform destroy`. 그 후 로컬에서 Bastion 제거.
  - 권장 순서: module4 → module3 → module2 → module1/k8s → module1 → (로컬) bastion
  - EKS 를 private-only 로 바꾼 경우 destroy 전 public endpoint 재오픈 필요.
```powershell
cd C:\Users\competitor\2026-terraform\04\2과제\bastion
terraform destroy -auto-approve   # Bastion + 부트스트랩 버킷만 제거
```

## ⚠️ 문제지 ↔ 채점표(mark 스크립트) 불일치 — **채점표 기준으로 구현함**
채점은 `mark1~4.sh` 의 exact-match 로 진행되므로, 문제지와 다를 경우 **채점표 기대 출력**을 따랐다. 실제 대회 mark 스크립트가 문제지 표기를 쓰면 아래를 되돌릴 것.

| 항목 | 문제지 | 채점표(적용값) |
|------|--------|---------------|
| module1 서브넷 이름 | `wsc-scaling-sn-pub-a` … | **`wsc-scaling-pub-sn-a`** …(1-1-A) |
| module1 EKS 버전 | 미명시 | **1.35**(1-2-A) |
| module3 VPC Name 태그 | `wsc-logging-vpc` | **`wsc-log-vpc`**(3-1-A 필터) |
| module3 서브넷 CIDR | priv-a=10.3.2, pub-c=10.3.1 | **priv-a=10.3.1, pub-c=10.3.2**(3-1-A) |
| module3 NodeGroup max | 미명시 | **maxSize 4**(3-1-A) |
| module3 App EC2 Name | `wsc-logging-app-bastion` | **`wsc-log-app-bastion`**(3-3-A 필터) |
| module4 DynamoDB 키 | name(PK) + age 속성 | **name 단일 PK**(4-3-A delete-item) |
| module3 대시보드 label | `wsc-app-log` | 3-5-B=`wsc-app-log`(자동), 3-6-B=`wsc2026-app-log`(수동, 오타 의심) → **`wsc-app-log` 유지** |

## NEEDS-REVIEW
- Karpenter/KEDA/LB Controller/Loki/Grafana 의 helm 차트 버전은 대회 시점 최신에 맞춰 필요 시 핀 고정.
- EKS 1.35 에서 Service type=LoadBalancer(NLB) 는 AWS Load Balancer Controller 필요 → `setup.sh` 가 노드 롤 크리덴셜로 설치. 컨트롤러 기동 실패 시 `kubectl -n kube-system logs deploy/aws-load-balancer-controller` 확인.
- 로그 발생→Grafana 도달 10초 이내 요건: Fluent Bit `Flush 1`, dashboard refresh 5s 로 설정됨.

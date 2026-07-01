# 03 / 제2과제 (Small Challenge) — Terraform 2단계 배포

CDN · Keycloak · Container Logging · Workflow 4개 모듈을 **모듈별 독립 state**로
구성하고, **로컬(Windows) → Linux Bastion** 2단계로 배포합니다.

## 리전 / 모듈 개요

| 모듈 | 주제 | 리전 | 주요 리소스 |
|------|------|------|-------------|
| module1 | CDN | **us-east-1** | S3(OAC), CloudFront `wsc2026-cdn`, CF Functions(device-detect/response-header), Lambda@Edge `wsc2026-resize` |
| module2 | Keycloak | **ap-northeast-2** | VPC `wsc2026-keycloak-vpc`, ALB, EC2 Keycloak, IAM SAML(`wsc2026-keycloak-idp`) + dev/infra Role |
| module3 | Container Logging | **ap-northeast-1** | EKS `wsc2026-logging-cluster`(v1.35, PUBLIC), Fluent Bit→OTel→Loki/Prometheus→Grafana |
| module4 | Workflow | **ap-southeast-1** | S3 `wsc2026-order-pipeline`, DynamoDB×3, Lambda×2, Step Functions `wsc2026-order-pipeline` |

> module1 의 Lambda@Edge / CloudFront Function 은 us-east-1 필수입니다.
> module3 EKS endpoint 는 채점 요구에 따라 **PUBLIC** 으로 둡니다(닫지 않음).

## 2단계 배포 흐름

```
[1단계] 로컬 Windows PowerShell
   cd bastion
   terraform init
   terraform apply              # (선택) -var "player_id=<id>" -var "pin=<비번호>"
   #  -> Bastion EC2 + 부트스트랩 S3(코드 번들) 생성
   #     버킷명: <player_id>-task2-03-bootstrap-<account_id>

[2단계] Bastion (SSM 접속, Linux)
   aws ssm start-session --target <bastion_id> --region ap-northeast-2
   until [ -f /opt/task2/READY ]; do sleep 5; done
   bash /opt/task2/deploy.sh <비번호>
   #  -> module1 -> module2 -> module3(+EKS helm/kubectl) -> module4 순서 apply

[채점 직전] 로컬에서 Bastion 만 제거 (모듈 리소스는 유지)
   cd bastion; terraform destroy -auto-approve
```

모든 배포 스크립트는 **bash** 입니다(PowerShell 미사용). Pillow 빌드(module1),
Keycloak SAML 연동(module2), helm/kubectl(module3) 모두 Linux Bastion 에서 동작합니다.

### 로컬(Windows) 직접 apply 가능 모듈

- **module4 (Workflow, VPC 없음)**: S3+DynamoDB+Lambda(python3.13)+Step Functions
  로만 구성되어 Linux 의존(프로비저너/도커/헬름)이 전혀 없다. bastion 없이
  로컬 Windows PowerShell 에서 바로 생성된다.
  ```powershell
  cd C:\Users\competitor\2026-terraform\03\2과제\module4
  terraform init
  terraform apply
  ```
- **module1 (CDN, VPC 없음)**: 서버리스지만 Lambda@Edge 용 **Pillow(manylinux) 레이어
  빌드**가 필요해 Linux Bastion 에서 apply 한다(로컬 Windows 는 `/bin/bash`
  provisioner 미지원). deploy.sh 에 포함.
- **module2/module3 (VPC 있음)**: Bastion 에서 apply.

## 디렉터리 구조

```
03/2과제/
├── module1/                CDN (us-east-1)
│   ├── main.tf
│   ├── functions/          device-detect.js, response-header.js (cloudfront-js-2.0)
│   ├── lambda/resize.py    Lambda@Edge (python3.12, Pillow)
│   ├── build.sh            Pillow manylinux 빌드
│   └── assets/worldskills_banner.png
├── module2/                Keycloak (ap-northeast-2)
│   ├── main.tf
│   ├── userdata.sh.tpl     Keycloak 설치 + Realm/그룹/사용자/SAML Client
│   └── saml-iam.sh         IAM SAML Provider + dev/infra Role (런타임)
├── module3/                Container Logging (ap-northeast-1)
│   ├── network.tf, eks.tf, outputs.tf
│   ├── app/app.py          log-generator (JSON 로그)
│   ├── k8s/deployment.yaml
│   ├── helm/*.yaml         fluent-bit / otel / loki / prometheus / grafana values
│   ├── helm/dashboard.json wsc2026-app-logs
│   └── deploy_k8s.sh       EKS k8s/Helm 배포 (bastion 실행)
├── module4/                Workflow (ap-southeast-1)
│   ├── main.tf
│   ├── lambda/validator|payment/handler.py (python3.13)
│   └── assets/sample-orders.json, inventory-seed.json
├── bastion/                1단계 Bastion (S3-bundle, SSM, AdministratorAccess)
│   ├── main.tf, variables.tf, versions.tf, outputs.tf, userdata.sh.tpl
└── README.md
```

## NEEDS-REVIEW (terraform validate 로 검증 불가 — 런타임/수동 확인 필요)

- **module1 배포파일**: `assets/worldskills_banner.png` 는 지급 배포파일 원본
  (111811 bytes)으로 교체 완료. terraform 이 `origin/worldskills_banner.png` 로
  업로드한다(채점 1-1). 리사이즈 결과 크기(mobile 113209 / desktop 121900)는
  Pillow 버전에 따라 미세하게 달라질 수 있는 런타임 산출값이다(채점 1-6, NEEDS-REVIEW).
- **module1 device 헤더**: 디바이스 감지는 `CloudFront-Is-Mobile-Viewer` 등 viewer
  단계 헤더에 의존합니다(런타임).
- **module2 Keycloak/SAML**: Realm/그룹/사용자/SAML Client 는 EC2 `user_data`
  (`userdata.sh.tpl`, Keycloak 26 + kcadm)로 자동 구성되고, IAM SAML Provider
  (`wsc2026-keycloak-idp`)/Role(dev·infra)은 `saml-iam.sh`(local-exec, apply 시
  bastion 리눅스에서 실행)가 ALB 경유 실제 Realm descriptor 를 받아 등록한다.
  dev/infra 관리형 정책만 terraform 이 관리한다. SAML SSO 콘솔 로그인(2-6)은
  수동 검증 항목이다. (`saml-metadata.xml` 은 더 이상 사용하지 않음)
- **module3 EKS o11y**: Fluent Bit / OTel / Loki / Prometheus / Grafana 는 Helm
  으로 배포되며 `terraform validate` 대상이 아닙니다. Loki Push 는 OTLP(`/otlp/v1/logs`)
  로 전송합니다. CloudShell 채점 시 EKS access 가 필요하면
  `GRADER_ARN=<arn> bash deploy_k8s.sh` 로 access entry 를 부여하세요.
- **module4 Step Functions(4-6)**: E2E 실행 결과(주문 적재/재고 차감/이력)는 런타임
  검증 항목입니다. `valid_orders` 카운트는 ArrayLength 근사값입니다.

## 검증

각 디렉터리에서 `terraform fmt`, `terraform init -backend=false`,
`terraform validate` 가 모두 `Success` 입니다. (plan/apply 는 수행하지 않음)


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\03\2과제\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.

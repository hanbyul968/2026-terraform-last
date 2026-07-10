# 05 제2과제 — 콘솔 솔루션 (처음부터 끝까지)

AWS 콘솔 + CloudShell로 4개 모듈을 직접 구성하는 전체 가이드.
비번호는 예시로 `101`을 사용 — 본인 비번호로 바꾸세요.

## 모듈 / 리전

| 모듈 | 리전 | 내용 | 배점 | 가이드 |
|---|---|---|---|---|
| 1. CDN | **us-east-1** | S3 + Lambda + Lambda@Edge + CloudFront | 7.5 | [01-CDN.md](01-CDN.md) |
| 2. Real-time data | **ap-southeast-1** | Kafka(EC2) + NLB + Flink(Zeppelin) | 7.5 | [02-Data.md](02-Data.md) |
| 3. Cloud event | **ap-northeast-2** | FastAPI(EC2) + CloudWatch + Lambda + EventBridge | 7.5 | [03-Event.md](03-Event.md) |
| 4. Keycloak | **eu-central-1** | Keycloak(EC2) + OIDC + IAM Role | 7.5 | [04-Keycloak.md](04-Keycloak.md) |

## 공통 사전 준비

1. 각 모듈은 **리전이 다릅니다.** 콘솔 우상단 리전을 그때그때 맞추세요.
2. EC2는 별도 명시 없으면 **t3.small / Amazon Linux 2023 / Default VPC**.
3. 배포파일(app.py, dog.png)은 **수정 없이** 사용.
4. Security Group 80/443 outbound는 any open.

## 배포파일 위치
과제 배포파일(`dog.png`, `app.py` 2종)을 CloudShell로 올리거나, 로컬에서 준비.
`repo의 05/2과제/files/` 에도 동일 파일이 있습니다.

## 진행 순서 (권장)
서로 독립이라 순서 무관하지만, 시간이 오래 걸리는 것부터:
1. **Module 2** (Kafka EC2 + Flink Studio가 제일 오래 걸림 → 먼저 시작)
2. **Module 4** (Keycloak 기동 대기)
3. **Module 1** (CloudFront 배포 대기)
4. **Module 3** (비교적 빠름)

각 모듈 파일에 **① 콘솔 단계 → ② 붙여넣을 코드/스크립트 → ③ 채점 검증**까지 순서대로 있습니다.

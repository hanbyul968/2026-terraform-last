# 제2과제 — AWS 콘솔 솔루션 가이드 (09)

terraform 없이 **AWS 웹 콘솔 클릭만으로** 제2과제를 처음부터 끝까지 구성하는 방법.

## 과제 구성 (모듈마다 리전 다름 — 꼭 확인!)

| 모듈 | 주제 | 리전 | 가이드 |
|------|------|------|--------|
| 1 | EKS Scaling (KEDA + Karpenter) | **ap-northeast-2** (서울) | [module1-eks-scaling.md](module1-eks-scaling.md) |
| 2 | Container Logging (Loki + Grafana) | **ap-southeast-2** (시드니) | [module2-container-logging.md](module2-container-logging.md) |
| 3 | MSK (Kafka + Lambda + DynamoDB) | **ap-northeast-3** (오사카) | [module3-msk.md](module3-msk.md) |
| 4 | REST API (API GW + Lambda + DynamoDB) | **ap-southeast-1** (싱가포르) | [module4-rest-api.md](module4-rest-api.md) |

각 4모듈 7.5점, 총 30점.

## 공통 준비

1. AWS 콘솔 로그인
2. **우측 상단 리전 선택** — 모듈마다 지정된 리전으로 반드시 바꿀 것 (가장 흔한 실수)
3. EKS 조작이 필요한 모듈(1, 2)은 **CloudShell** 또는 **bastion EC2**에서 `kubectl`/`helm` 사용
4. 비번호가 들어가는 이름(예: S3 버킷)은 **본인 비번호로 치환**

## 진행 순서 팁
- 모듈은 서로 독립적이라 순서 무관, 병렬로 해도 됨
- EKS 클러스터 생성은 10~15분, MSK는 15~25분 걸리니 **먼저 생성 걸어두고** 다른 작업 진행
- 이름/태그는 채점 스크립트가 정확히 매칭하므로 **오타 주의**

## 각 모듈 요약 값

| 항목 | 모듈1 | 모듈2 | 모듈3 | 모듈4 |
|------|-------|-------|-------|-------|
| VPC CIDR | 10.0.0.0/16 | 10.0.0.0/16 | 10.0.0.0/16 | (기본/불필요) |
| 클러스터/핵심 | wsi-eks | wsc2026-logging-cluster | msk-order-cluster | wsc2026-worldschool-api |
| 핵심 리소스 | KEDA, Karpenter | Loki, Grafana, ALB | MSK, Lambda, DynamoDB | Lambda, Layer, DynamoDB |

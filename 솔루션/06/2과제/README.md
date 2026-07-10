# 제2과제 — AWS 콘솔 솔루션 (처음부터 끝까지)

2026 전국기능경기대회 클라우드컴퓨팅 **제2과제(Small Challenge)** 를
**AWS Management Console(웹 UI)** 만으로 수행하는 단계별 가이드입니다.
(Terraform 없이, 콘솔 클릭 위주 + kubectl/helm 이 꼭 필요한 부분만 CloudShell 사용)

## 모듈 구성

| 모듈 | 문서 | 리전 | 핵심 서비스 |
|------|------|------|-------------|
| 1) NoSQL | [1_NoSQL.md](1_NoSQL.md) | `ap-southeast-1` (싱가포르) | DynamoDB, Streams, Lambda, EC2(Flask) |
| 2) CDN Function | [2_CDN_Function.md](2_CDN_Function.md) | `us-east-1` (버지니아 북부) | S3, CloudFront, CF Functions, KVS |
| 3) EKS Scaling | [3_EKS_Scaling.md](3_EKS_Scaling.md) | `ap-northeast-2` (서울) | SQS, EKS, KEDA, Karpenter |
| 4) Container Logging | [4_Container_Logging.md](4_Container_Logging.md) | `ap-northeast-1` (도쿄) | EKS, ALB, OTel, Loki, Grafana |

> ⚠️ **리전 주의**: 각 모듈은 서로 다른 리전에서 작업합니다.
> 콘솔 **우측 상단 리전 선택기**에서 반드시 해당 리전으로 바꾼 뒤 시작하세요.
> 리전이 틀리면 리소스가 안 보이거나 채점이 되지 않습니다.

---

## 공통 준비

### 0-1. 로그인 & 리전 확인
1. AWS Management Console 로그인.
2. 우측 상단에서 **작업할 리전**을 선택 (모듈별 리전 표 참고).

### 0-2. 계정 ID 확인 (S3 버킷 이름 등에 사용)
- 우측 상단 계정 메뉴 → **계정 ID(12자리)** 를 메모해 둡니다. (예: `640107381732`)
- 또는 CloudShell에서:
  ```bash
  aws sts get-caller-identity --query Account --output text
  ```

### 0-3. CloudShell 여는 법
- 콘솔 우측 상단 **터미널 아이콘( >_ )** 클릭 → 현재 리전에서 CloudShell 이 열립니다.
- kubectl/helm 이 필요한 모듈 3·4 의 일부 단계에서 사용합니다.
- **리전이 맞는 CloudShell** 인지 항상 확인하세요(좌측 상단에 리전 표시).

### 0-4. 배포파일 위치
아래 파일들의 내용은 각 모듈 문서 안에 그대로 인용되어 있으니, 복사해서 붙여 넣으면 됩니다.
- module1: `app.py`, `lambda.py`
- module2: `index_a.html`, `index_b.html`, `cf_req_fn.js`, `cf_res_fn.js`
- module3: `app.py`, `Dockerfile`, `requirements.txt`
- module4: `app.py`, `Dockerfile`

---

## 공통 규칙 (과제지 유의사항 요약)

- 이름·태그·변수는 **대소문자 구분**. 문제지에 명시된 이름을 그대로 사용.
- 보안그룹은 채점 편의를 위해 **80/443 Outbound 는 Anyopen(0.0.0.0/0)** 허용.
- IAM Policy 는 `Principal: "*"`, `Action: "*"` 같은 광범위 권한 **금지** → 최소권한.
- 모든 EC2 는 **t3.small** + **Amazon Linux 2023** AMI 사용(특별 지시 없을 시).
- `{a,b,c}` 표기는 각각 전개해서 생성 (예: `subnet-pub-{a,b}` → `-a`, `-b`).

---

## 진행 순서 권장

모듈 간 의존성은 없으므로 순서 무관하지만, 리전 전환 최소화를 위해 아래 순서를 권장합니다.

```
1) NoSQL          (ap-southeast-1)  ─ DynamoDB/Lambda/EC2, 콘솔로 대부분 완결
2) CDN Function   (us-east-1)       ─ S3/CloudFront, 콘솔로 완결
3) EKS Scaling    (ap-northeast-2)  ─ 콘솔로 EKS/IAM/SQS, CloudShell로 helm/kubectl
4) Container Log  (ap-northeast-1)  ─ 콘솔로 EKS/ALB/IAM, CloudShell로 helm/kubectl
```

각 문서 하단에는 **검증(채점 스크립트 기준)** 절이 있어, 만든 리소스가 채점 기대값과
맞는지 바로 확인할 수 있습니다.

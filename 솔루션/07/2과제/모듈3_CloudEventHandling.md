# 모듈 3 — Cloud Event Handling (콘솔)

**리전: 싱가포르 `ap-southeast-1`** — 리전 선택기 먼저 싱가포르로!

> 보호 대상 SG에 인바운드 규칙이 추가되면 → **CloudTrail → EventBridge → Lambda** 가 감지해서
> 규칙을 0개로 되돌리고 SNS 알림을 발행합니다.

## 목표 흐름

```
누군가 skills-ceh-protected-sg 에 Inbound 추가
   │ (AuthorizeSecurityGroupIngress API)
   ▼
CloudTrail(skills-ceh-cloudtrail) 기록
   ▼
EventBridge Rule(skills-ceh-sg-change-rule) 매칭
   ▼
Lambda(skills-ceh-remediate-fn) 실행
   ├─ Inbound 규칙 0개로 복구
   └─ SNS(skills-ceh-alert-topic) 알림 발행
```

## 고정 이름 요약

| 항목 | 값 |
|------|-----|
| VPC / CIDR | `skills-ceh-vpc` / `10.73.0.0/16` |
| EC2 | `skills-ceh-ec2` |
| 보호 SG | `skills-ceh-protected-sg` (최종 Inbound 0개) |
| SNS Topic | `skills-ceh-alert-topic` (Standard) |
| Lambda | `skills-ceh-remediate-fn` (python3.12, timeout≥30) |
| CloudTrail | `skills-ceh-cloudtrail` |
| EventBridge Rule | `skills-ceh-sg-change-rule` (default bus) |

---

## 1단계. VPC / EC2 / 보호 SG

### VPC
`[VPC > VPC 생성]` — "VPC 등"
- 이름: **`skills-ceh-vpc`**, CIDR **`10.73.0.0/16`**
- 퍼블릭 서브넷 1개(`10.73.1.0/24`) + IGW + 퍼블릭 라우팅

### 보호 대상 SG
`[EC2 > 보안 그룹 > 생성]`
- 이름/이름 태그: **`skills-ceh-protected-sg`**
- VPC: `skills-ceh-vpc`
- **인바운드 규칙: 없음(0개)** ← 그대로 비워둠
- 아웃바운드: 전체 허용

### EC2
`[EC2 > 인스턴스 시작]`
- 이름: **`skills-ceh-ec2`**
- AMI: Amazon Linux 2023, `t3.micro`
- 네트워크: `skills-ceh-vpc`, 퍼블릭 서브넷
- 보안 그룹: **`skills-ceh-protected-sg`**
- 시작

---

## 2단계. SNS 토픽

`[SNS > 주제 > 주제 생성]`
- 유형: **표준(Standard)**
- 이름: **`skills-ceh-alert-topic`**
- 생성 → **ARN 복사** (Lambda 환경변수에 사용)
- (선택) 이메일 구독을 추가하면 알림을 눈으로 확인 가능(채점 필수는 아님)

---

## 3단계. Lambda

### 3-1. 실행 역할
`[IAM > 역할 > 생성]` — 신뢰 엔터티 **Lambda**
- 인라인 정책(JSON):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ec2:DescribeSecurityGroups","ec2:RevokeSecurityGroupIngress"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["sns:Publish"], "Resource": "<skills-ceh-alert-topic ARN>" },
    { "Effect": "Allow", "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], "Resource": "*" }
  ]
}
```
- 역할 이름: `skills-ceh-lambda-role`

### 3-2. 함수 생성
`[Lambda > 함수 > 함수 생성]`
- 새로 작성, 이름: **`skills-ceh-remediate-fn`**
- 런타임: **Python 3.12**
- 실행 역할: 기존 역할 `skills-ceh-lambda-role`
- 생성 후 **코드** 탭에 제공 `remediate_security_group.py` 내용을 붙여넣기
  - 파일명이 `remediate_security_group.py` 여야 핸들러가 맞습니다.
- **핸들러**: `remediate_security_group.lambda_handler` (구성 > 런타임 설정 > 편집)
- **구성 > 일반 구성**: 제한 시간 **30초 이상**
- **구성 > 환경 변수**:
  - `PROTECTED_SECURITY_GROUP_ID` = `skills-ceh-protected-sg` 의 **SG ID**(`sg-...`)
  - `SNS_TOPIC_ARN` = `skills-ceh-alert-topic` **ARN**
- **Deploy(배포)**

---

## 4단계. CloudTrail

`[CloudTrail > 추적 > 추적 생성]`
- 추적 이름: **`skills-ceh-cloudtrail`**
- 스토리지: 새 S3 버킷 생성(이름 자유, Global Unique → 필요 시 `<비번호>` 포함)
- 로그 이벤트: **관리 이벤트**(쓰기 포함) 활성 — `AuthorizeSecurityGroupIngress` 가 관리 이벤트로 기록됨
- **로깅 활성화** 확인
- 생성

> 채점에서 `IsLogging=True` 를 확인합니다.

---

## 5단계. EventBridge 규칙

`[EventBridge > 규칙 > 규칙 생성]`
- 이름: **`skills-ceh-sg-change-rule`**
- 이벤트 버스: **default**
- 규칙 유형: **이벤트 패턴이 있는 규칙**
- 이벤트 패턴(사용자 지정 패턴 JSON):
```json
{
  "source": ["aws.ec2"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["ec2.amazonaws.com"],
    "eventName": ["AuthorizeSecurityGroupIngress"]
  }
}
```
- 대상: **Lambda 함수 → `skills-ceh-remediate-fn`**
- 생성

> 규칙 생성 시 콘솔이 Lambda 에 **호출 권한(리소스 정책)** 을 자동 추가합니다.
> (채점에서 `lambda get-policy` 로 events.amazonaws.com 허용을 확인)

---

## 6단계. 동작 테스트

```bash
REGION=ap-southeast-1
SG=$(aws ec2 describe-security-groups --region $REGION \
  --filters Name=tag:Name,Values=skills-ceh-protected-sg \
  --query "SecurityGroups[0].GroupId" --output text)

# 1) 규칙 임시 추가 (테스트)
aws ec2 authorize-security-group-ingress --region $REGION --group-id "$SG" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

# 2) Lambda 직접 호출(이벤트 형식과 동일 payload)
aws lambda invoke --region $REGION --function-name skills-ceh-remediate-fn \
  --cli-binary-format raw-in-base64-out \
  --payload "$(jq -n --arg sg "$SG" '{detail:{eventName:"AuthorizeSecurityGroupIngress",requestParameters:{groupId:$sg}}}')" \
  /tmp/out.json && cat /tmp/out.json

# 3) 180초 내 Inbound 0개 복구 확인
aws ec2 describe-security-groups --region $REGION --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions" --output json   # []
```

## 체크리스트
- [ ] VPC 10.73.0.0/16, EC2 running, 보호 SG 존재
- [ ] 보호 SG **최종 Inbound 0개**
- [ ] SNS 표준 토픽, Lambda py3.12/handler/timeout≥30/환경변수 2개
- [ ] CloudTrail 로깅 ON, EventBridge 패턴/타깃 정확, Lambda 리소스 정책 존재
- [ ] 테스트 후 180초 내 복구 + `/aws/lambda/skills-ceh-remediate-fn` 로그 그룹 생성

> ⚠️ 최종 제출 전, 테스트로 넣은 규칙이 **모두 제거(0개)** 됐는지 반드시 확인!

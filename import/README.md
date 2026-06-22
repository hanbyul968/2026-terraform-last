# Terraform Import Helper

terraform apply 시 **"이미 존재함"** 에러(`EntityAlreadyExists`, `AlreadyExists`,
`BucketAlreadyOwnedByYou` 등)가 뜨면, 에러 메시지를 통째로 붙여넣어
어떤 `terraform import` 명령어를 실행해야 하는지 알려주는 웹 도구.

특정 과제 전용이 아니라 **어떤 terraform 프로젝트에서도** 동작한다.

## 실행

```bash
pip install -r requirements.txt
python app.py
# 브라우저 http://127.0.0.1:5000 접속
```

## 사용법

1. (필요 시) `-var="number=..."` 같은 변수 값 입력 — 없으면 비워둠
2. terraform 에러 메시지를 통째로 붙여넣기
3. "Import 명령어 생성" 클릭
4. 리소스별 import 명령어 + 전체 묶음 출력

## 동작 원리

1. 에러를 `Error:` 블록 단위로 분리
2. 각 블록에서 **리소스 주소**(`with <addr>,`)와 **이미 존재하는 이름**
   (`creating ... (NAME):` 괄호 안)을 추출
3. 리소스 *타입*(`aws_iam_role`, `aws_s3_bucket`, `aws_subnet` ...)별 import ID 규칙을 참조
   - **name 기반**(IAM Role, S3, DynamoDB, ECR, Lambda 등): 에러에서 추출한 이름을 그대로 import ID 로 사용 → 바로 실행 가능한 명령어 출력
   - **ID 기반**(VPC, Subnet, SG, KMS Key, ALB 등): import ID(예: `subnet-xxx`)를 구하는
     `aws` CLI 조회 명령어를 함께 안내

## 지원 리소스 타입

`app.py` 의 `TYPE_SPECS` 에 정의. IAM / S3 / DynamoDB / ECR / Lambda / KMS /
VPC·Subnet·NAT·RT·SG·EIP·IGW·FlowLog·Endpoint / ALB·TG·Listener /
CloudFront·WAF / EKS·ECS / RDS / SNS·SQS·SecretsManager·Route53 등.

### 타입 추가/수정

```python
TYPE_SPECS["aws_xxx"] = {
    "id_kind": "import ID 설명",
    "from_err": True,            # 에러 괄호 안 이름을 그대로 import ID 로 쓸 수 있으면 True
    "needs": "aws ... 조회 명령", # ID 를 따로 구해야 할 때의 힌트(선택)
}
```

> 등록되지 않은 타입이어도 `terraform import <addr> <ID>` 기본 형식과
> Registry 문서 참고 안내를 출력하므로 막히지 않는다.

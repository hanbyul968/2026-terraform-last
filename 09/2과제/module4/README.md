# Module 4 - REST API Implement (ap-southeast-1)

## 실행

```bash
terraform init
terraform apply --auto-approve
```

완료. 추가 작업 없음.

## 동작 확인

```bash
API_ID=$(aws apigateway get-rest-apis --region ap-southeast-1 \
  --query "items[?name=='wsc2026-worldschool-api'].id" --output text)
URL=https://${API_ID}.execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage

# POST
curl -X POST -d '{"admission_year": 2026, "student_name":"홍길동"}' \
  -w "\n%{http_code}\n" $URL

# GET 전체
curl -X GET -w "\n%{http_code}\n" $URL

# GET 특정
curl -G -d "admission_year=2026" --data-urlencode "student_name=홍길동" \
  -w "\n%{http_code}\n" $URL
```

## 채점 정보

| 항목        | 값                                                                   |
| ----------- | -------------------------------------------------------------------- |
| Lambda      | wsc2026-worldschool-management                                       |
| Layer       | wsc2026-worldschool-env-layer                                        |
| DynamoDB    | wsc2026-worldschool-table (PK: admission_year N, SK: student_name S) |
| API Gateway | wsc2026-worldschool-api                                              |
| Stage       | wsc2026-worldschool-api-stage                                        |

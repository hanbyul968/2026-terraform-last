#!/bin/bash
# 새 채점기준표 1번 Workflow (ap-southeast-1) 자기검증
# 사용: number=102 bash mark1.sh          (클렌징 확인 → test.csv 업로드 → 60초 후 채점)
#       number=102 SKIP_UPLOAD=1 bash mark1.sh   (업로드 없이 현재 상태만 확인)
#
# 채점 순서(채점기준표 원문)
#   1) S3 버킷·DynamoDB 데이터 클렌징 확인 — 남아 있으면 1-1, 1-5, 1-6 은 오답
#   2) s3://<bucket>/input/test.csv 업로드 후 60초 경과 뒤 1-1 ~ 1-6 확인

REGION="ap-southeast-1"
NUMBER="${number:-102}"
BUCKET_NAME="wsc2026-student-score-bucket-${NUMBER}"
TABLE_NAME="wsc2026-student-score"
FUNCTION_NAME="wsc2026-student-score-function"
CSV="$(cd "$(dirname "$0")" && pwd)/module1/test.csv"
aws configure set region "$REGION"

echo "===================================================="
echo " 1-0 사전 준비 (클렌징 확인 + test.csv 업로드)"
echo "===================================================="
echo "ACCOUNT ID : $(aws sts get-caller-identity --query Account --output text)"
echo "REGION     : $REGION"
echo "BUCKET_NAME: $BUCKET_NAME"

S3_LEFT=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo "NA")
DDB_LEFT=$(aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --query Count --output text 2>/dev/null || echo "NA")
echo "클렌징 상태 : S3 objects=$S3_LEFT / DynamoDB items=$DDB_LEFT  (둘 다 0 이어야 함)"
if [ "$S3_LEFT" != "0" ] || [ "$DDB_LEFT" != "0" ]; then
  echo "!! 경고: 데이터가 남아 있으면 1-1, 1-5, 1-6 이 모두 오답 처리된다. 'BIBUNHO=$NUMBER bash cleanup.sh' 실행 필요."
fi

if [ "${SKIP_UPLOAD:-0}" != "1" ]; then
  echo "input/test.csv 업로드 → 60초 대기"
  aws s3 cp "$CSV" "s3://$BUCKET_NAME/input/test.csv" --only-show-errors
  sleep 60
fi

echo
echo "===================================================="
echo " 1-1 S3 Bucket + Folder Structure"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
                           PRE error/
                           PRE input/
                           PRE processed/
EXPECT
echo "--- 실제출력 -------------------------------------"
aws s3api head-bucket --bucket "$BUCKET_NAME" 2>&1 > /dev/null && aws s3 ls "s3://$BUCKET_NAME/"

echo
echo "===================================================="
echo " 1-2 DynamoDB Table + Key Schema"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
["wsc2026-student-score",[{"AttributeName":"studentId","KeyType":"HASH"},{"AttributeName":"examDate","KeyType":"RANGE"}]]
EXPECT
echo "--- 실제출력 -------------------------------------"
aws dynamodb describe-table --table-name "$TABLE_NAME" --query "Table.[TableName,KeySchema]" --output json

echo
echo "===================================================="
echo " 1-3 Lambda Function + Runtime + Env"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<EXPECT
["wsc2026-student-score-function","python3.12",{"S3_BUCKET":"$BUCKET_NAME","DDB_TABLE":"wsc2026-student-score"}]
EXPECT
echo "--- 실제출력 -------------------------------------"
aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
  --query "[FunctionName,Runtime,Environment.Variables]" --output json

echo
echo "===================================================="
echo " 1-4 Step Functions State Machine"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
wsc2026-student-score-workflow  STANDARD
EXPECT
echo "--- 실제출력 -------------------------------------"
SM_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='wsc2026-student-score-workflow'].stateMachineArn" --output text)
aws stepfunctions describe-state-machine --state-machine-arn "$SM_ARN" --query "[name,type]" --output text

echo
echo "===================================================="
echo " 1-5 Workflow Result (Normal)"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
STU1020 96.6    A
<date> <time>   497 test.csv
EXPECT
echo "--- 실제출력 -------------------------------------"
aws dynamodb get-item --table-name "$TABLE_NAME" \
  --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
  --query "Item.[studentId.S,average.N,grade.S]" --output text
aws s3 ls "s3://$BUCKET_NAME/processed/"

echo
echo "===================================================="
echo " 1-6 Workflow Result (Error)"
echo "===================================================="
echo "--- 기대값 (4개, 그 외 출력되면 오답) ------------"
cat <<'EXPECT'
error_<timestamp>_STU2001.json
error_<timestamp>_STU2002.json
error_<timestamp>_STU2004.json
error_<timestamp>_unknown.json
EXPECT
echo "--- 실제출력 -------------------------------------"
aws s3 ls "s3://$BUCKET_NAME/error/"
echo "error object 수: $(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix error/ --query 'length(Contents || `[]`)' --output text) (4 이어야 함)"

echo
echo "===================================================="
echo " 1번 Workflow 채점 종료"
echo " ※ 확인이 끝나면 반드시 클렌징: BIBUNHO=$NUMBER bash cleanup.sh"
echo "===================================================="

#!/bin/bash
# 새 채점기준표 3번 MSK (ap-northeast-1) 자기검증
#   과제지 12항: 기존 3번 Cloud Event Handling 삭제 → 4번 MSK 가 3번 채점항목
# 사용: number=102 bash mark3.sh
# 채점기준표 원문 명령을 그대로 사용한다.
#
# ⚠ 채점기준표 3번 사전준비의 BUCKET_NAME 이 "wsc2026-student-score-bucket-<등번호>" 로 적혀 있으나
#   3-1 기대 출력은 arn:aws:s3:::wsc2026-sensor-alert-bucket-<등번호> / BucketRegion ap-northeast-1 이다.
#   (채점지 오기. 같은 이름의 버킷을 두 리전에 만들 수 없으므로 alert 버킷으로 확인한다.)

REGION="ap-northeast-1"
NUMBER="${number:-102}"
CLUSTER_NAME="wsc2026-msk-cluster"
TABLE_NAME="wsc2026-sensor-data"
BUCKET_NAME="wsc2026-sensor-alert-bucket-${NUMBER}"
RAW_FUNCTION="wsc2026-sensor-consumer"
ALERT_FUNCTION="wsc2026-sensor-alert-consumer"
aws configure set region "$REGION"

echo "===================================================="
echo " 3-0 사전 준비"
echo "===================================================="
echo "ACCOUNT ID : $(aws sts get-caller-identity --query Account --output text)"
echo "REGION     : $REGION"
echo "BUCKET_NAME: $BUCKET_NAME"
CLUSTER_ARN=$(aws kafka list-clusters --cluster-name-filter "$CLUSTER_NAME" --query "ClusterInfoList[0].ClusterArn" --output text)
echo "CLUSTER_ARN: $CLUSTER_ARN"

echo
echo "===================================================="
echo " 3-1 Resources (DynamoDB + S3)"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<EXPECT
wsc2026-sensor-data     sensorId        timestamp
{
    "BucketArn": "arn:aws:s3:::$BUCKET_NAME",
    "BucketRegion": "ap-northeast-1",
    "AccessPointAlias": false
}
EXPECT
echo "--- 실제출력 -------------------------------------"
aws dynamodb describe-table --table-name "$TABLE_NAME" --query "Table.[TableName,KeySchema[*].AttributeName]" --output text \
  && aws s3api head-bucket --bucket "$BUCKET_NAME" 2>&1

echo
echo "===================================================="
echo " 3-2 Lambda Functions"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
wsc2026-sensor-consumer python3.14
wsc2026-sensor-alert-consumer    python3.14
EXPECT
echo "--- 실제출력 -------------------------------------"
for fn in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do
  aws lambda get-function --function-name "$fn" --query "Configuration.[FunctionName,Runtime]" --output text
done

echo
echo "===================================================="
echo " 3-3 MSK Cluster Configuration"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
wsc2026-msk-cluster     ACTIVE  3.6.0   kafka.t3.small  True
"wsc2026-sensor-alert",2,1
"wsc2026-sensor-raw",2,3
EXPECT
echo "--- 실제출력 -------------------------------------"
aws kafka describe-cluster --cluster-arn "$CLUSTER_ARN" \
  --query "ClusterInfo.[ClusterName,State,CurrentBrokerSoftwareInfo.KafkaVersion,BrokerNodeGroupInfo.InstanceType,ClientAuthentication.Sasl.Iam.Enabled]" --output text
aws kafka list-topics --output json --cluster-arn "$CLUSTER_ARN" \
  --query "Topics[].[TopicName,ReplicationFactor,PartitionCount]" 2>/dev/null | grep -A2 wsc2026 \
  || echo "(list-topics 미지원 CLI 버전이면 producer EC2 에서 확인: /var/log/module3-bootstrap.log 의 'Created topic')"

echo
echo "===================================================="
echo " 3-4 MSK Trigger Mapping"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
printf 'Enabled\nEnabled\n'
echo "--- 실제출력 -------------------------------------"
for fn in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do
  aws lambda list-event-source-mappings --function-name "$fn" --query "EventSourceMappings[0].[State]" --output text
done

echo
echo "===================================================="
echo " 3-5 Data Processing Result"
echo "===================================================="
echo "--- 기대값 (Key 3개가 모두 표시되어야 함) --------"
cat <<'EXPECT'
{
    "sensorId": "SENSOR-002",
    "temperature": "64.6",
    "status": "NORMAL"
}
EXPECT
echo "--- 실제출력 -------------------------------------"
aws dynamodb scan --table-name "$TABLE_NAME" --max-items 1 \
  --query "Items[0].{sensorId:sensorId.S,temperature:temperature.S,status:status.S}" --output json

echo
echo "===================================================="
echo " 3-6 timestamp ISO 8601 KST"
echo "===================================================="
echo "--- 기대값 (YYYY-MM-DDTHH:mm:ss+09:00) -----------"
cat <<'EXPECT'
{
    "sensorId": "SENSOR-002",
    "timestamp": "2026-06-01T18:28:24+09:00"
}
EXPECT
echo "--- 실제출력 -------------------------------------"
SCAN=$(aws dynamodb scan --table-name "$TABLE_NAME" --max-items 3 \
  --query "Items[*].{sensorId:sensorId.S,timestamp:timestamp.S}" --output json)
echo "$SCAN"
if printf '%s' "$SCAN" | grep -Eq '"timestamp": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00"'; then
  echo "timestamp 형식 PASS (+09:00)"
else
  echo "timestamp 형식 FAIL — ISO 8601 KST(+09:00) 아님"
fi

echo
echo "===================================================="
echo " (배점표 3-6) Producer Running"
echo "===================================================="
PRODUCER_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-sensor-producer" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
echo "PRODUCER_ID: $PRODUCER_ID (running 이어야 함)"
if [ "$PRODUCER_ID" != "None" ] && [ -n "$PRODUCER_ID" ]; then
  CMD_ID=$(aws ssm send-command --instance-ids "$PRODUCER_ID" --document-name "AWS-RunShellScript" \
    --parameters '{"commands":["systemctl is-active producer-iam && systemctl is-enabled producer-iam"]}' \
    --query "Command.CommandId" --output text 2>/dev/null)
  if [ -n "$CMD_ID" ]; then
    sleep 5
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$PRODUCER_ID" --query "StandardOutputContent" --output text
  fi
fi

echo
echo "===================================================="
echo " 3번 MSK 채점 종료"
echo "===================================================="

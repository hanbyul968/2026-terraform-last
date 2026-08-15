#!/bin/bash
# 채점기준표_vf.pdf 4-0 ~ 4-5 (MSK, ap-northeast-1)
# rubric 원문 명령을 그대로 사용한다. 사용법: number=<비번호> bash mark4.sh
#
# 참고) rubric 4-1~4-4는 "명령 블록"과 "기대 출력"이 서로 밀려 있다(rubric 자체 오류).
#       따라서 각 항목마다 rubric 명령 + 항목명(배점표)에 해당하는 실제 확인값을 함께 출력한다.
#         4-1 DynamoDB + S3   4-2 Lambda Resources   4-3 MSK Cluster
#         4-4 MSK Event(Trigger)   4-5 Data Flow

echo "===================================================="
echo " 4-0 채점환경 준비"
echo "===================================================="
REGION="ap-northeast-1"; CLUSTER_NAME="wsc2026-msk-cluster"; RAW_TOPIC="wsc2026-sensor-raw"; ALERT_TOPIC="wsc2026-sensor-alert"; TABLE_NAME="wsc2026-sensor-data"; RAW_FUNCTION="wsc2026-sensor-consumer"; ALERT_FUNCTION="wsc2026-sensor-alert-consumer"; NUMBER="${number:-}"; BUCKET_NAME="wsc2026-sensor-alert-bucket-${NUMBER}"; aws configure set region "$REGION"
echo "ACCOUNT ID : $(aws sts get-caller-identity --query Account --output text)"
echo "REGION     : $REGION"
echo "BUCKET_NAME: $BUCKET_NAME"
if [ -z "$NUMBER" ]; then echo "!! 경고: number 환경변수가 비어 있음. 'number=608 bash mark4.sh' 형태로 실행하세요."; fi

echo
echo "===================================================="
echo " 4-1 DynamoDB + S3"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
DynamoDB schema PASS
S3 bucket PASS
EXPECT
echo "--- 실제출력 -------------------------------------"
# DynamoDB 스키마(PK sensorId, SK timestamp) 확인
DDB_SCHEMA=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" --query "Table.[KeySchema[?KeyType=='HASH'].AttributeName|[0],KeySchema[?KeyType=='RANGE'].AttributeName|[0]]" --output text 2>/dev/null | tr '\t' ' ' | xargs)
[ "$DDB_SCHEMA" = "sensorId timestamp" ] && echo "DynamoDB schema PASS" || echo "DynamoDB schema FAIL (actual: $DDB_SCHEMA)"
# S3 버킷 존재 확인
aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" >/dev/null 2>&1 && echo "S3 bucket PASS" || echo "S3 bucket FAIL ($BUCKET_NAME)"
# (rubric 명령: VPC/서브넷 검사 — 참고용)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=msk-vpc" --query 'Vpcs[0].VpcId' --output text); VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null); VPC_RESULT=PASS; [ "$VPC_CIDR" = "192.168.0.0/16" ] || VPC_RESULT=FAIL; for subnet in "msk-pub-a:192.168.0.0/24" "msk-pub-d:192.168.1.0/24" "msk-priv-a:192.168.10.0/24" "msk-priv-d:192.168.11.0/24"; do NAME=${subnet%%:*}; EXPECTED_CIDR=${subnet##*:}; ACTUAL_CIDR=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME" --query 'Subnets[0].CidrBlock' --output text); [ "$ACTUAL_CIDR" = "$EXPECTED_CIDR" ] || VPC_RESULT=FAIL; done
echo "(참고) rubric VPC/Subnet 검사: $VPC_RESULT"

echo
echo "===================================================="
echo " 4-2 Lambda Resources"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
wsc2026-sensor-consumer PASS
wsc2026-sensor-alert-consumer PASS
EXPECT
echo "--- 실제출력 -------------------------------------"
for FUNCTION_NAME in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do
  RT=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" --query 'Runtime' --output text 2>/dev/null)
  if [ "$RT" = "python3.14" ]; then echo "$FUNCTION_NAME PASS"; else echo "$FUNCTION_NAME FAIL (runtime: $RT)"; fi
done

echo
echo "===================================================="
echo " 4-3 MSK Cluster"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
MSK cluster PASS
EXPECT
echo "--- 실제출력 -------------------------------------"
CLUSTER_ARN=$(aws kafka list-clusters-v2 --region "$REGION" --query "ClusterInfoList[?ClusterName=='$CLUSTER_NAME'].ClusterArn | [0]" --output text); MSK_INFO=$(aws kafka describe-cluster-v2 --cluster-arn "$CLUSTER_ARN" --region "$REGION" --query 'ClusterInfo.[ClusterName,State,Provisioned.CurrentBrokerSoftwareInfo.KafkaVersion,Provisioned.BrokerNodeGroupInfo.InstanceType,Provisioned.ClientAuthentication.Sasl.Iam.Enabled]' --output text | tr '\t' ' ' | xargs); SUBNET_COUNT=$(aws kafka describe-cluster-v2 --cluster-arn "$CLUSTER_ARN" --region "$REGION" --query 'length(ClusterInfo.Provisioned.BrokerNodeGroupInfo.ClientSubnets)' --output text)
if [ "$MSK_INFO" = "$CLUSTER_NAME ACTIVE 3.6.0 kafka.t3.small True" ] && [ "$SUBNET_COUNT" -ge 2 ] 2>/dev/null; then echo "MSK cluster PASS"; else echo "MSK cluster FAIL"; echo "  actual: $MSK_INFO / subnets=$SUBNET_COUNT"; fi

echo
echo "===================================================="
echo " 4-4 MSK Event (Trigger Mapping)"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
wsc2026-sensor-consumer PASS
wsc2026-sensor-alert-consumer PASS
EXPECT
echo "--- 실제출력 -------------------------------------"
RAW_MAPPING=$(aws lambda list-event-source-mappings --function-name "$RAW_FUNCTION" --region "$REGION" --query "EventSourceMappings[?contains(Topics, '$RAW_TOPIC')].State | [0]" --output text); ALERT_MAPPING=$(aws lambda list-event-source-mappings --function-name "$ALERT_FUNCTION" --region "$REGION" --query "EventSourceMappings[?contains(Topics, '$ALERT_TOPIC')].State | [0]" --output text)
[ "$RAW_MAPPING" = Enabled ] && echo "$RAW_FUNCTION PASS" || echo "$RAW_FUNCTION FAIL (state: $RAW_MAPPING)"
[ "$ALERT_MAPPING" = Enabled ] && echo "$ALERT_FUNCTION PASS" || echo "$ALERT_FUNCTION FAIL (state: $ALERT_MAPPING)"
# (rubric 4-4 명령: Runtime+Handler 정확 일치 — 참고용)
LAMBDA_RESULT=PASS; for FUNCTION_NAME in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do CONFIG=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" --query '[Runtime,Handler]' --output text | tr '\t' ' ' | xargs); [ "$CONFIG" = "python3.14 wsc2026.consumer_handler" ] || LAMBDA_RESULT=FAIL; done; [ "$RAW_MAPPING" = Enabled ] && [ "$ALERT_MAPPING" = Enabled ] || LAMBDA_RESULT=FAIL
echo "(참고) rubric Runtime+Handler(python3.14 wsc2026.consumer_handler) 검사: $LAMBDA_RESULT"
for FUNCTION_NAME in "$RAW_FUNCTION" "$ALERT_FUNCTION"; do echo "  $FUNCTION_NAME -> $(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" --query '[Runtime,Handler]' --output text | tr '\t' ' ' | xargs)"; done

echo
echo "===================================================="
echo " 4-5 Data Flow"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
DynamoDB sensor item PASS
S3 alert object PASS
EXPECT
echo "--- 실제출력 -------------------------------------"
ITEM_COUNT=$(aws dynamodb scan --table-name "$TABLE_NAME" --region "$REGION" --select COUNT --query Count --output text); [ "$ITEM_COUNT" -gt 0 ] 2>/dev/null && echo "DynamoDB sensor item PASS (count=$ITEM_COUNT)" || echo "DynamoDB sensor item FAIL (count=$ITEM_COUNT)"; S3_COUNT=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix alert/ --region "$REGION" --query 'length(Contents || `[]`)' --output text 2>/dev/null); [ "$S3_COUNT" -gt 0 ] 2>/dev/null && echo "S3 alert object PASS (count=$S3_COUNT)" || echo "S3 alert object FAIL (count=$S3_COUNT)"

echo
echo "===================================================="
echo " 모듈4 채점 종료"
echo "===================================================="

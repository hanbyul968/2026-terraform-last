#!/bin/bash
# 새 채점기준표 2번 Real-time Data Analytics (ap-northeast-2) 자기검증
# 사용: bash mark2.sh
# 채점기준표 원문 명령을 그대로 사용한다.

REGION="ap-northeast-2"
aws configure set region "$REGION"

echo "===================================================="
echo " 2-0 사전 준비"
echo "===================================================="
echo "ACCOUNT ID : $(aws sts get-caller-identity --query Account --output text)"
echo "REGION     : $REGION"
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb --query "LoadBalancers[0].DNSName" --output text)
EC2_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-analytics-ec2" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
echo "ALB_DNS    : $ALB_DNS"
echo "EC2_ID     : $EC2_ID"

echo
echo "===================================================="
echo " 2-1 EC2 Instance (Subnet 확인)"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
echo "analytics-priv-a"
echo "--- 실제출력 -------------------------------------"
aws ec2 describe-subnets --subnet-ids "$(aws ec2 describe-instances --instance-ids "$EC2_ID" --query "Reservations[0].Instances[0].SubnetId" --output text)" \
  --query "Subnets[0].Tags[?Key=='Name'].Value|[0]" --output text
echo "(참고) Instance Type: $(aws ec2 describe-instances --instance-ids "$EC2_ID" --query "Reservations[0].Instances[0].InstanceType" --output text) (t3.small 이어야 함)"

echo
echo "===================================================="
echo " 2-2 ALB Resources"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
cat <<'EXPECT'
80      HTTP
wsc2026-analytics-tg    5000
EXPECT
echo "--- 실제출력 -------------------------------------"
aws elbv2 describe-listeners --load-balancer-arn "$(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query "Listeners[].[Port,Protocol]" --output text
aws elbv2 describe-target-groups --names wsc2026-analytics-tg --query "TargetGroups[].[TargetGroupName,Port]" --output text

echo
echo "===================================================="
echo " 2-3 Kinesis Stream"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
echo "wsc2026-order-stream    ACTIVE  ON_DEMAND"
echo "--- 실제출력 -------------------------------------"
aws kinesis describe-stream-summary --stream-name wsc2026-order-stream \
  --query "StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]" --output text

echo
echo "===================================================="
echo " 2-4 Kinesis Data (POST /order)"
echo "===================================================="
echo "--- 기대값 (모든 필드가 채워진 JSON) -------------"
cat <<'EXPECT'
{ "event_time": "...", "order_id": "...", "price": 1200000, "product_name": "...", "quantity": 2 }
EXPECT
echo "--- 실제출력 -------------------------------------"
curl -s -X POST "http://$ALB_DNS/order" | jq .

echo
echo "===================================================="
echo " 2-5 Flink Application"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
echo "wsc2026-analytics-flink READY   ZEPPELIN-FLINK-3_0"
echo "--- 실제출력 -------------------------------------"
aws kinesisanalyticsv2 describe-application --application-name wsc2026-analytics-flink \
  --query "ApplicationDetail.[ApplicationName,ApplicationStatus,RuntimeEnvironment]" --output text

echo
echo "===================================================="
echo " 2-6 Application Health"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
echo '{"status":"healthy"}'
echo "--- 실제출력 -------------------------------------"
curl -s "http://$ALB_DNS/health"; echo

echo
echo "===================================================="
echo " 2-7 Systemd Service"
echo "===================================================="
echo "--- 기대값 ---------------------------------------"
printf 'active\nenabled\n'
echo "--- 실제출력 -------------------------------------"
CMD_ID=$(aws ssm send-command --instance-ids "$EC2_ID" --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl is-active app && systemctl is-enabled app"]}' \
  --query "Command.CommandId" --output text)
sleep 5
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$EC2_ID" --query "StandardOutputContent" --output text

echo
echo "===================================================="
echo " 2번 Real-time Data Analytics 채점 종료"
echo "===================================================="

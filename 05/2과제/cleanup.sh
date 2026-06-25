#!/bin/bash
# 05/2과제 - 고아 리소스 정리 (state 유실 후 AlreadyExists 충돌 해결용)
# 로컬(Git Bash) 또는 CloudShell에서 실행. AWS CLI 자격증명 필요.
# best-effort: 없는 리소스는 무시(|| true)

set +e
PIN="${1:-101}"

echo "##### Module 1: CDN (us-east-1) #####"
R=us-east-1
# CloudFront 배포 비활성화 + 삭제 (gj2026-cdn comment)
DID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='gj2026-cdn'].Id" --output text)
for d in $DID; do
  ETAG=$(aws cloudfront get-distribution-config --id "$d" --query ETag --output text)
  aws cloudfront get-distribution-config --id "$d" --query DistributionConfig > /tmp/cf.json
  python -c "import json;c=json.load(open('/tmp/cf.json'));c['Enabled']=False;json.dump(c,open('/tmp/cf.json','w'))"
  aws cloudfront update-distribution --id "$d" --distribution-config file:///tmp/cf.json --if-match "$ETAG" >/dev/null
  echo "  CloudFront $d 비활성화 요청 (Deployed까지 대기 후 삭제 필요)"
  aws cloudfront wait distribution-deployed --id "$d"
  ETAG2=$(aws cloudfront get-distribution-config --id "$d" --query ETag --output text)
  aws cloudfront delete-distribution --id "$d" --if-match "$ETAG2" && echo "  CloudFront $d 삭제"
done
# OAC / Cache Policy
OACID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='gj2026-cdn-oac'].Id" --output text)
[ -n "$OACID" ] && aws cloudfront delete-origin-access-control --id "$OACID" --if-match "$(aws cloudfront get-origin-access-control --id "$OACID" --query ETag --output text)" && echo "  OAC 삭제"
CPID=$(aws cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='gj2026-cdn-cache-policy'].CachePolicy.Id" --output text)
[ -n "$CPID" ] && aws cloudfront delete-cache-policy --id "$CPID" --if-match "$(aws cloudfront get-cache-policy --id "$CPID" --query ETag --output text)" && echo "  CachePolicy 삭제"
# Lambda (edge는 배포 삭제 후 수시간 뒤 가능할 수 있음)
for fn in gj2026-cdn-rotate gj2026-cdn-request gj2026-cdn-response; do
  aws lambda delete-function --function-name "$fn" --region $R 2>/dev/null && echo "  Lambda $fn 삭제"
done
# IAM role
aws iam delete-role-policy --role-name gj2026-cdn-lambda-role --policy-name gj2026-cdn-s3 2>/dev/null
aws iam detach-role-policy --role-name gj2026-cdn-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
aws iam delete-role --role-name gj2026-cdn-lambda-role 2>/dev/null && echo "  IAM role gj2026-cdn-lambda-role 삭제"
# S3 버킷 비우고 삭제
aws s3 rb "s3://gj2026-cdn-bucket-$PIN" --force 2>/dev/null && echo "  S3 버킷 삭제"

echo "##### Module 2: data (ap-southeast-1) #####"
R=ap-southeast-1
aws kinesisanalyticsv2 delete-application --application-name gj2026-data-zeppelin --region $R \
  --create-timestamp "$(aws kinesisanalyticsv2 describe-application --application-name gj2026-data-zeppelin --region $R --query 'ApplicationDetail.CreateTimestamp' --output text 2>/dev/null)" 2>/dev/null && echo "  Zeppelin 삭제"
# EC2
IID=$(aws ec2 describe-instances --region $R --filters "Name=tag:Name,Values=gj2026-data-ec2" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IID" ] && aws ec2 terminate-instances --region $R --instance-ids $IID >/dev/null && echo "  EC2 $IID 종료" && aws ec2 wait instance-terminated --region $R --instance-ids $IID
# NLB + TG
LBARN=$(aws elbv2 describe-load-balancers --region $R --names gj2026-data-nlb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
[ -n "$LBARN" ] && [ "$LBARN" != "None" ] && aws elbv2 delete-load-balancer --region $R --load-balancer-arn "$LBARN" && echo "  NLB 삭제" && sleep 20
TGARN=$(aws elbv2 describe-target-groups --region $R --names gj2026-data-kafka-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
[ -n "$TGARN" ] && [ "$TGARN" != "None" ] && aws elbv2 delete-target-group --region $R --target-group-arn "$TGARN" && echo "  TG 삭제"
# SG
SGID=$(aws ec2 describe-security-groups --region $R --filters "Name=group-name,Values=gj2026-data-kafka-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SGID" ] && [ "$SGID" != "None" ] && aws ec2 delete-security-group --region $R --group-id "$SGID" 2>/dev/null && echo "  SG 삭제"
# Glue
aws glue delete-database --name real_time_analytics --region $R 2>/dev/null && echo "  Glue DB 삭제"
# IAM
for r in gj2026-data-ec2-role gj2026-data-flink-role; do
  aws iam remove-role-from-instance-profile --instance-profile-name gj2026-data-ec2-profile --role-name "$r" 2>/dev/null
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do aws iam detach-role-policy --role-name "$r" --policy-arn "$p"; done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do aws iam delete-role-policy --role-name "$r" --policy-name "$p"; done
  aws iam delete-role --role-name "$r" 2>/dev/null && echo "  IAM role $r 삭제"
done
aws iam delete-instance-profile --instance-profile-name gj2026-data-ec2-profile 2>/dev/null

echo "##### Module 3: event (ap-northeast-2) #####"
R=ap-northeast-2
IID=$(aws ec2 describe-instances --region $R --filters "Name=tag:Name,Values=gj2026-event-ec2" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IID" ] && aws ec2 terminate-instances --region $R --instance-ids $IID >/dev/null && echo "  EC2 $IID 종료" && aws ec2 wait instance-terminated --region $R --instance-ids $IID
for fn in gj2026-event-updater gj2026-event-recovery; do aws lambda delete-function --function-name "$fn" --region $R 2>/dev/null && echo "  Lambda $fn 삭제"; done
aws events remove-targets --rule gj2026-event-trigger-alarm --ids gj2026-event-recovery --region $R 2>/dev/null
aws events delete-rule --name gj2026-event-trigger-alarm --region $R 2>/dev/null && echo "  EventBridge rule 삭제"
aws cloudwatch delete-alarms --alarm-names gj2026-event-app-alarm --region $R 2>/dev/null && echo "  Alarm 삭제"
for lg in /gj2026/event/app-logs /gj2026/event/recovery /aws/lambda/gj2026-event-updater /aws/lambda/gj2026-event-recovery; do aws logs delete-log-group --log-group-name "$lg" --region $R 2>/dev/null && echo "  LogGroup $lg 삭제"; done
aws ssm delete-parameter --name /gj2026/event/app-py --region $R 2>/dev/null && echo "  SSM param 삭제"
TOPIC=$(aws sns list-topics --region $R --query "Topics[?contains(TopicArn,'gj2026-event-alarm-topic')].TopicArn" --output text)
[ -n "$TOPIC" ] && aws sns delete-topic --topic-arn "$TOPIC" --region $R && echo "  SNS topic 삭제"
SGID=$(aws ec2 describe-security-groups --region $R --filters "Name=group-name,Values=gj2026-event-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SGID" ] && [ "$SGID" != "None" ] && aws ec2 delete-security-group --region $R --group-id "$SGID" 2>/dev/null && echo "  SG 삭제"
for r in gj2026-event-ec2-role gj2026-event-lambda-role; do
  aws iam remove-role-from-instance-profile --instance-profile-name gj2026-event-ec2-profile --role-name "$r" 2>/dev/null
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do aws iam detach-role-policy --role-name "$r" --policy-arn "$p"; done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do aws iam delete-role-policy --role-name "$r" --policy-name "$p"; done
  aws iam delete-role --role-name "$r" 2>/dev/null && echo "  IAM role $r 삭제"
done
aws iam delete-instance-profile --instance-profile-name gj2026-event-ec2-profile 2>/dev/null

echo "##### Module 4: keycloak (eu-central-1) #####"
R=eu-central-1
IID=$(aws ec2 describe-instances --region $R --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IID" ] && aws ec2 terminate-instances --region $R --instance-ids $IID >/dev/null && echo "  EC2 $IID 종료" && aws ec2 wait instance-terminated --region $R --instance-ids $IID
SGID=$(aws ec2 describe-security-groups --region $R --filters "Name=group-name,Values=gj2026-keycloak-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SGID" ] && [ "$SGID" != "None" ] && aws ec2 delete-security-group --region $R --group-id "$SGID" 2>/dev/null && echo "  SG 삭제"
# OIDC provider (realms/team 포함)
for arn in $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text); do
  echo "$arn" | grep -q "realms/team" && aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" && echo "  OIDC $arn 삭제"
done
for r in gj2026-keycloak-ec2-role gj2026-keycloak-dev-role gj2026-keycloak-sec-role; do
  aws iam remove-role-from-instance-profile --instance-profile-name gj2026-keycloak-ec2-profile --role-name "$r" 2>/dev/null
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do aws iam detach-role-policy --role-name "$r" --policy-arn "$p"; done
  aws iam delete-role --role-name "$r" 2>/dev/null && echo "  IAM role $r 삭제"
done
aws iam delete-instance-profile --instance-profile-name gj2026-keycloak-ec2-profile 2>/dev/null
ACCT=$(aws sts get-caller-identity --query Account --output text)
for p in gj2026-keycloak-dev-policy gj2026-keycloak-sec-policy; do
  aws iam delete-policy --policy-arn "arn:aws:iam::$ACCT:policy/$p" 2>/dev/null && echo "  IAM policy $p 삭제"
done

echo "##### 정리 완료. terraform state도 초기화하려면: rm -f terraform.tfstate* #####"

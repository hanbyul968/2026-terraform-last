#!/bin/bash
# 05/2과제 고아 리소스 정리 (cleanup.ps1 의 bash 변환본)
# state 유실 후 AlreadyExists 충돌 해결용. AWS CLI 자격증명 필요.
# 사용: bash cleanup.sh [비번호]   (기본 101)
# $ErrorActionPreference="Continue" 와 동일하게 개별 명령 실패는 무시하고 진행한다.
set -uo pipefail

PIN="${1:-101}"

# ---- 공용 함수 ----
remove_role_all() {
  local role="$1" profile="$2"
  if [ -n "$profile" ]; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
  fi
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    [ -n "$p" ] && aws iam detach-role-policy --role-name "$role" --policy-arn "$p" 2>/dev/null || true
  done
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
    [ -n "$p" ] && aws iam delete-role-policy --role-name "$role" --policy-name "$p" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$role" 2>/dev/null || true
}

term_ec2() {
  local name="$1" region="$2"
  local ids
  ids=$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$ids" ]; then
    aws ec2 terminate-instances --region "$region" --instance-ids $ids >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --region "$region" --instance-ids $ids || true
    echo "  EC2 $name 종료"
  fi
}

del_sg() {
  local name="$1" region="$2"
  local sg
  sg=$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=group-name,Values=$name" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [ -n "$sg" ] && [ "$sg" != "None" ]; then
    aws ec2 delete-security-group --region "$region" --group-id "$sg" 2>/dev/null || true
    echo "  SG $name 삭제"
  fi
}

echo "##### Module 1: CDN (us-east-1) #####"
R="us-east-1"
DID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='gj2026-cdn'].Id" --output text)
for d in $DID; do
  [ -z "$d" ] && continue
  etag=$(aws cloudfront get-distribution-config --id "$d" --query ETag --output text)
  aws cloudfront get-distribution-config --id "$d" --query DistributionConfig --output json > "/tmp/cf-$d.json"
  jq '.Enabled=false' "/tmp/cf-$d.json" > "/tmp/cf-$d-off.json"
  aws cloudfront update-distribution --id "$d" --distribution-config "file:///tmp/cf-$d-off.json" --if-match "$etag" >/dev/null 2>&1 || true
  echo "  $d 비활성화, deployed 대기..."
  aws cloudfront wait distribution-deployed --id "$d" || true
  etag2=$(aws cloudfront get-distribution-config --id "$d" --query ETag --output text)
  aws cloudfront delete-distribution --id "$d" --if-match "$etag2" && echo "  $d 삭제"
done

cp=$(aws cloudfront list-cache-policies --type custom \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='gj2026-cdn-cache-policy'].CachePolicy.Id" --output text)
if [ -n "$cp" ] && [ "$cp" != "None" ]; then
  aws cloudfront delete-cache-policy --id "$cp" --if-match "$(aws cloudfront get-cache-policy --id "$cp" --query ETag --output text)" && echo "  cache-policy 삭제"
fi

oac=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='gj2026-cdn-oac'].Id" --output text)
if [ -n "$oac" ] && [ "$oac" != "None" ]; then
  aws cloudfront delete-origin-access-control --id "$oac" --if-match "$(aws cloudfront get-origin-access-control --id "$oac" --query ETag --output text)" && echo "  OAC 삭제"
fi

for fn in gj2026-cdn-rotate gj2026-cdn-request gj2026-cdn-response; do
  aws lambda delete-function --function-name "$fn" --region "$R" 2>/dev/null || true
done
aws iam delete-role-policy --role-name gj2026-cdn-lambda-role --policy-name gj2026-cdn-s3 2>/dev/null || true
aws iam detach-role-policy --role-name gj2026-cdn-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name gj2026-cdn-lambda-role 2>/dev/null || true
aws s3 rb "s3://gj2026-cdn-bucket-$PIN" --force 2>/dev/null || true

echo "##### Module 2: data (ap-southeast-1) #####"
R="ap-southeast-1"
ts=$(aws kinesisanalyticsv2 describe-application --application-name gj2026-data-zeppelin --region "$R" --query 'ApplicationDetail.CreateTimestamp' --output text 2>/dev/null)
if [ -n "$ts" ] && [ "$ts" != "None" ]; then
  aws kinesisanalyticsv2 delete-application --application-name gj2026-data-zeppelin --region "$R" --create-timestamp "$ts" && echo "  Zeppelin 삭제"
fi
term_ec2 "gj2026-data-ec2" "$R"
lb=$(aws elbv2 describe-load-balancers --region "$R" --names gj2026-data-nlb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ -n "$lb" ] && [ "$lb" != "None" ]; then
  aws elbv2 delete-load-balancer --region "$R" --load-balancer-arn "$lb" && echo "  NLB 삭제" && sleep 20
fi
tg=$(aws elbv2 describe-target-groups --region "$R" --names gj2026-data-kafka-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [ -n "$tg" ] && [ "$tg" != "None" ]; then
  aws elbv2 delete-target-group --region "$R" --target-group-arn "$tg" && echo "  TG 삭제"
fi
del_sg "gj2026-data-kafka-sg" "$R"
aws glue delete-database --name real_time_analytics --region "$R" 2>/dev/null || true
remove_role_all "gj2026-data-ec2-role" "gj2026-data-ec2-profile"
remove_role_all "gj2026-data-flink-role" ""
aws iam delete-instance-profile --instance-profile-name gj2026-data-ec2-profile 2>/dev/null || true

echo "##### Module 3: event (ap-northeast-2) #####"
R="ap-northeast-2"
term_ec2 "gj2026-event-ec2" "$R"
for fn in gj2026-event-updater gj2026-event-recovery; do
  aws lambda delete-function --function-name "$fn" --region "$R" 2>/dev/null || true
done
aws events remove-targets --rule gj2026-event-trigger-alarm --ids gj2026-event-recovery --region "$R" 2>/dev/null || true
aws events delete-rule --name gj2026-event-trigger-alarm --region "$R" 2>/dev/null || true
aws cloudwatch delete-alarms --alarm-names gj2026-event-app-alarm --region "$R" 2>/dev/null || true
for lg in "/gj2026/event/app-logs" "/gj2026/event/recovery" "/aws/lambda/gj2026-event-updater" "/aws/lambda/gj2026-event-recovery"; do
  aws logs delete-log-group --log-group-name "$lg" --region "$R" 2>/dev/null || true
done
aws ssm delete-parameter --name /gj2026/event/app-py --region "$R" 2>/dev/null || true
topic=$(aws sns list-topics --region "$R" --query "Topics[?contains(TopicArn,'gj2026-event-alarm-topic')].TopicArn" --output text)
if [ -n "$topic" ] && [ "$topic" != "None" ]; then
  aws sns delete-topic --topic-arn "$topic" --region "$R" || true
fi
del_sg "gj2026-event-sg" "$R"
remove_role_all "gj2026-event-ec2-role" "gj2026-event-ec2-profile"
remove_role_all "gj2026-event-lambda-role" ""
aws iam delete-instance-profile --instance-profile-name gj2026-event-ec2-profile 2>/dev/null || true

echo "##### Module 4: keycloak (eu-central-1) #####"
R="eu-central-1"
term_ec2 "gj2026-keycloak-ec2" "$R"
del_sg "gj2026-keycloak-sg" "$R"
for arn in $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text); do
  [ -z "$arn" ] && continue
  case "$arn" in
    *realms/team*)
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" && echo "  OIDC 삭제"
      ;;
  esac
done
remove_role_all "gj2026-keycloak-ec2-role" "gj2026-keycloak-ec2-profile"
remove_role_all "gj2026-keycloak-dev-role" ""
remove_role_all "gj2026-keycloak-sec-role" ""
aws iam delete-instance-profile --instance-profile-name gj2026-keycloak-ec2-profile 2>/dev/null || true
acct=$(aws sts get-caller-identity --query Account --output text)
for p in gj2026-keycloak-dev-policy gj2026-keycloak-sec-policy; do
  aws iam delete-policy --policy-arn "arn:aws:iam::${acct}:policy/$p" 2>/dev/null || true
done

echo "##### 정리 완료. state 초기화: rm -f terraform.tfstate* #####"

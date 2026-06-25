# 05/2과제 고아 리소스 정리 (PowerShell)
# state 유실 후 AlreadyExists 충돌 해결용. AWS CLI 자격증명 필요.
# 사용: powershell -ExecutionPolicy Bypass -File cleanup.ps1 101
param([string]$Pin = "101")
$ErrorActionPreference = "Continue"

Write-Host "##### Module 1: CDN (us-east-1) #####"
$R = "us-east-1"
$DID = aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='gj2026-cdn'].Id" --output text
foreach ($d in ($DID -split "\s+" | Where-Object { $_ })) {
  $etag = aws cloudfront get-distribution-config --id $d --query ETag --output text
  $f = Join-Path $env:TEMP "cf-$d.json"
  aws cloudfront get-distribution-config --id $d --query DistributionConfig --output json | Out-File $f -Encoding ascii
  $c = Get-Content $f -Raw | ConvertFrom-Json
  $c.Enabled = $false
  ($c | ConvertTo-Json -Depth 30) | Out-File $f -Encoding ascii
  aws cloudfront update-distribution --id $d --distribution-config "file://$f" --if-match $etag *> $null
  Write-Host "  $d 비활성화, deployed 대기..."
  aws cloudfront wait distribution-deployed --id $d
  $etag2 = aws cloudfront get-distribution-config --id $d --query ETag --output text
  aws cloudfront delete-distribution --id $d --if-match $etag2; Write-Host "  $d 삭제"
}
$cp = aws cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='gj2026-cdn-cache-policy'].CachePolicy.Id" --output text
if ($cp) { aws cloudfront delete-cache-policy --id $cp --if-match (aws cloudfront get-cache-policy --id $cp --query ETag --output text); Write-Host "  cache-policy 삭제" }
$oac = aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='gj2026-cdn-oac'].Id" --output text
if ($oac) { aws cloudfront delete-origin-access-control --id $oac --if-match (aws cloudfront get-origin-access-control --id $oac --query ETag --output text); Write-Host "  OAC 삭제" }
foreach ($fn in @("gj2026-cdn-rotate","gj2026-cdn-request","gj2026-cdn-response")) { aws lambda delete-function --function-name $fn --region $R 2>$null }
aws iam delete-role-policy --role-name gj2026-cdn-lambda-role --policy-name gj2026-cdn-s3 2>$null
aws iam detach-role-policy --role-name gj2026-cdn-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>$null
aws iam delete-role --role-name gj2026-cdn-lambda-role 2>$null
aws s3 rb "s3://gj2026-cdn-bucket-$Pin" --force 2>$null

function Remove-RoleAll($role, $profile) {
  if ($profile) { aws iam remove-role-from-instance-profile --instance-profile-name $profile --role-name $role 2>$null }
  foreach ($p in (aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>$null) -split "\s+" | Where-Object { $_ }) { aws iam detach-role-policy --role-name $role --policy-arn $p 2>$null }
  foreach ($p in (aws iam list-role-policies --role-name $role --query 'PolicyNames[]' --output text 2>$null) -split "\s+" | Where-Object { $_ }) { aws iam delete-role-policy --role-name $role --policy-name $p 2>$null }
  aws iam delete-role --role-name $role 2>$null
}
function Term-EC2($name, $region) {
  $ids = aws ec2 describe-instances --region $region --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].InstanceId' --output text
  if ($ids) { aws ec2 terminate-instances --region $region --instance-ids ($ids -split "\s+") *> $null; aws ec2 wait instance-terminated --region $region --instance-ids ($ids -split "\s+"); Write-Host "  EC2 $name 종료" }
}
function Del-SG($name, $region) {
  $sg = aws ec2 describe-security-groups --region $region --filters "Name=group-name,Values=$name" --query 'SecurityGroups[0].GroupId' --output text 2>$null
  if ($sg -and $sg -ne "None") { aws ec2 delete-security-group --region $region --group-id $sg 2>$null; Write-Host "  SG $name 삭제" }
}

Write-Host "##### Module 2: data (ap-southeast-1) #####"
$R = "ap-southeast-1"
$ts = aws kinesisanalyticsv2 describe-application --application-name gj2026-data-zeppelin --region $R --query 'ApplicationDetail.CreateTimestamp' --output text 2>$null
if ($ts -and $ts -ne "None") { aws kinesisanalyticsv2 delete-application --application-name gj2026-data-zeppelin --region $R --create-timestamp $ts; Write-Host "  Zeppelin 삭제" }
Term-EC2 "gj2026-data-ec2" $R
$lb = aws elbv2 describe-load-balancers --region $R --names gj2026-data-nlb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>$null
if ($lb -and $lb -ne "None") { aws elbv2 delete-load-balancer --region $R --load-balancer-arn $lb; Write-Host "  NLB 삭제"; Start-Sleep 20 }
$tg = aws elbv2 describe-target-groups --region $R --names gj2026-data-kafka-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
if ($tg -and $tg -ne "None") { aws elbv2 delete-target-group --region $R --target-group-arn $tg; Write-Host "  TG 삭제" }
Del-SG "gj2026-data-kafka-sg" $R
aws glue delete-database --name real_time_analytics --region $R 2>$null
Remove-RoleAll "gj2026-data-ec2-role" "gj2026-data-ec2-profile"
Remove-RoleAll "gj2026-data-flink-role" $null
aws iam delete-instance-profile --instance-profile-name gj2026-data-ec2-profile 2>$null

Write-Host "##### Module 3: event (ap-northeast-2) #####"
$R = "ap-northeast-2"
Term-EC2 "gj2026-event-ec2" $R
foreach ($fn in @("gj2026-event-updater","gj2026-event-recovery")) { aws lambda delete-function --function-name $fn --region $R 2>$null }
aws events remove-targets --rule gj2026-event-trigger-alarm --ids gj2026-event-recovery --region $R 2>$null
aws events delete-rule --name gj2026-event-trigger-alarm --region $R 2>$null
aws cloudwatch delete-alarms --alarm-names gj2026-event-app-alarm --region $R 2>$null
foreach ($lg in @("/gj2026/event/app-logs","/gj2026/event/recovery","/aws/lambda/gj2026-event-updater","/aws/lambda/gj2026-event-recovery")) { aws logs delete-log-group --log-group-name $lg --region $R 2>$null }
aws ssm delete-parameter --name /gj2026/event/app-py --region $R 2>$null
$topic = aws sns list-topics --region $R --query "Topics[?contains(TopicArn,'gj2026-event-alarm-topic')].TopicArn" --output text
if ($topic) { aws sns delete-topic --topic-arn $topic --region $R }
Del-SG "gj2026-event-sg" $R
Remove-RoleAll "gj2026-event-ec2-role" "gj2026-event-ec2-profile"
Remove-RoleAll "gj2026-event-lambda-role" $null
aws iam delete-instance-profile --instance-profile-name gj2026-event-ec2-profile 2>$null

Write-Host "##### Module 4: keycloak (eu-central-1) #####"
$R = "eu-central-1"
Term-EC2 "gj2026-keycloak-ec2" $R
Del-SG "gj2026-keycloak-sg" $R
foreach ($arn in (aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text) -split "\s+" | Where-Object { $_ }) {
  if ($arn -match "realms/team") { aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $arn; Write-Host "  OIDC 삭제" }
}
Remove-RoleAll "gj2026-keycloak-ec2-role" "gj2026-keycloak-ec2-profile"
Remove-RoleAll "gj2026-keycloak-dev-role" $null
Remove-RoleAll "gj2026-keycloak-sec-role" $null
aws iam delete-instance-profile --instance-profile-name gj2026-keycloak-ec2-profile 2>$null
$acct = aws sts get-caller-identity --query Account --output text
foreach ($p in @("gj2026-keycloak-dev-policy","gj2026-keycloak-sec-policy")) { aws iam delete-policy --policy-arn "arn:aws:iam::${acct}:policy/$p" 2>$null }

Write-Host "##### 정리 완료. state 초기화: Remove-Item terraform.tfstate* #####"

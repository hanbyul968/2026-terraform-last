#!/bin/bash

aws configure set default.region ap-northeast-2

echo =====1-1=====
aws ec2 describe-vpcs --filter Name=tag:Name,Values=worldpay-vpc --query "Vpcs[].CidrBlock"
echo =============

echo =====1-2=====
aws ec2 describe-subnets --filter Name=tag:Name,Values=worldpay-public-subnet-a --query "Subnets[0].CidrBlock" \
; aws ec2 describe-subnets --filter Name=tag:Name,Values=worldpay-public-subnet-c --query "Subnets[0].CidrBlock" \
; aws ec2 describe-subnets --filter Name=tag:Name,Values=worldpay-isolated-subnet-a --query "Subnets[0].CidrBlock" \
; aws ec2 describe-subnets --filter Name=tag:Name,Values=worldpay-isolated-subnet-c --query "Subnets[0].CidrBlock"
echo =============

echo =====1-3=====
for s in worldpay-isolated-subnet-c worldpay-isolated-subnet-a; do
  subnet=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$s --query 'Subnets[0].SubnetId' --output text)
  count=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$subnet --query 'length(RouteTables[0].Routes[?NatGatewayId!=null])' --output text)
  [ "$count" -gt 0 ] && echo "$s: 1" || echo "$s: 0"
done
echo =============

echo =====2-1=====
aws ec2 describe-instances --filter Name=tag:Name,Values=worldpay-bastion --query "Reservations[].Instances[].PublicIpAddress"
aws ec2 describe-addresses --query "Addresses[].PublicIp"
echo =============

echo =====3-1=====
aws dynamodb describe-table --table-name Concerts --query "Table.SSEDescription.{Status:Status,SSEType:SSEType}" --output json && aws kms list-aliases --query "Aliases[?AliasName=='alias/worldpay-db-key'].AliasName" --output text
echo =============

echo =====3-2=====
TABLE_NAME=Concerts; aws dynamodb describe-continuous-backups --table-name $TABLE_NAME --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text; aws dynamodb describe-contributor-insights --table-name $TABLE_NAME --query 'ContributorInsightsStatus' --output text; aws dynamodb describe-table --table-name $TABLE_NAME --query 'Table.DeletionProtectionEnabled' --output text; aws dynamodb describe-table --table-name $TABLE_NAME --query 'Table.BillingModeSummary.BillingMode' --output text
echo =============

echo =====4-1=====
export BUCKET_NAME=worldpay-bucket-$(aws sts get-caller-identity --query Account --output text)
aws s3api get-bucket-encryption --bucket $BUCKET_NAME --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text && aws kms list-aliases --query "Aliases[?AliasName=='alias/worldpay-s3-key'].AliasName | [0]" --output text
echo =============

echo =====4-2=====
export BUCKET_NAME=worldpay-bucket-$(aws sts get-caller-identity --query Account --output text)
aws s3 ls s3://$BUCKET_NAME/ --recursive
echo =============

echo =====5-1=====
aws ecr describe-repositories --repository-names worldpay-book --query "repositories[0].{RepositoryName:repositoryName,ScanOnPush:imageScanningConfiguration.scanOnPush}"
echo =============

echo =====5-2=====
SIZE=$(aws ecr describe-images --repository-name worldpay-book --query 'imageDetails[0].imageSizeInBytes' --output text); TAG=$(aws ecr describe-images --repository-name worldpay-book --query 'imageDetails[0].imageTags[0]' --output text); echo "{\"ImageTag\":\"$TAG\",\"SizeMB\":\"$(awk "BEGIN{printf \"%.2f\",$SIZE/1024/1024}")\"}"
echo =============

echo =====6-1=====
aws elbv2 describe-load-balancers --names book-alb --query "LoadBalancers[0].{LoadBalancerName:LoadBalancerName,Scheme:Scheme,Type:Type,State:State.Code}"
echo =============

echo =====6-2=====
aws elbv2 describe-load-balancers --names grafana-alb --query "LoadBalancers[0].{LoadBalancerName:LoadBalancerName,Scheme:Scheme,Type:Type,State:State.Code}"
echo =============

echo =====7-1=====
aws eks describe-cluster --name worldpay-cluster --query "cluster.{Version:version,EndpointPublicAccess:resourcesVpcConfig.endpointPublicAccess,EndpointPrivateAccess:resourcesVpcConfig.endpointPrivateAccess}"
echo =============

echo =====7-2=====
NG=$(aws eks list-nodegroups --cluster-name worldpay-cluster --query "nodegroups[?starts_with(@, 'worldpay-nodegroup')] | [0]" --output text); aws eks describe-nodegroup --cluster-name worldpay-cluster --nodegroup-name "$NG" --query "nodegroup.{NodegroupName:'worldpay-nodegroup',InstanceTypes:instanceTypes,Status:status,DesiredSize:scalingConfig.desiredSize}"
echo =============

echo =====7-3=====
kubectl get serviceaccount book-sa -n worldpay -o json | jq '.metadata.name'
aws eks list-pod-identity-associations --cluster-name worldpay-cluster \
  --query "associations[?serviceAccount=='book-sa' && namespace=='worldpay']"
echo =============

echo =====7-4=====
CF_DOMAIN=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text); BOOKING_ID=$(curl -s -X POST https://$CF_DOMAIN/v1/book -H 'Content-Type: application/json' -d '{"client_id":"C001","username":"Alice","email":"alice@example.com","concert_name":"Seoul2026"}' | jq -r '.booking_id'); echo "{\"BookingId\":\"$BOOKING_ID\"}"; aws dynamodb get-item --table-name Concerts --key "{\"booking_id\":{\"S\":\"$BOOKING_ID\"}}" --query "Item.{BookingId:booking_id.S,ClientId:client_id.S,Username:username.S,Email:email.S,ConcertName:concert_name.S,CreatedAt:created_at.S}"
echo =============

echo =====8-1=====
DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='worldpay-cdn'].Id | [0]" --output text); aws cloudfront get-distribution --id "$DIST_ID" --query "Distribution.{Comment:DistributionConfig.Comment,DefaultRootObject:DistributionConfig.DefaultRootObject,PriceClass:DistributionConfig.PriceClass,Status:Status}"
echo =============

echo =====8-2=====
CF_DOMAIN=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text); curl -s -o /dev/null -w "%{http_code}\n" https://$CF_DOMAIN/; curl -s -X POST https://$CF_DOMAIN/v1/book -H 'Content-Type: application/json' -d '{"client_id":"C002","username":"Bob","email":"bob@example.com","concert_name":"Busan2026"}' | jq .
echo =============

echo =====9-1=====
kubectl get daemonset worldpay-fluentbit -n logging -o json | jq '{Name:.metadata.name,Namespace:.metadata.namespace}'
echo =============

echo =====9-2=====
aws logs describe-log-groups --log-group-name-prefix /worldpay/application --query "logGroups[].{LogGroupName:logGroupName,RetentionInDays:retentionInDays}"
echo =============

echo =====9-3=====
CF_DOMAIN=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text); curl -s -X POST https://$CF_DOMAIN/v1/book -H 'Content-Type: application/json' -d '{"client_id":"C003","username":"Carol","email":"carol@example.com","concert_name":"Format2026"}' >/dev/null; sleep 30; aws logs filter-log-events --log-group-name /worldpay/application --filter-pattern POST --output json | jq -r '.events | sort_by(.timestamp) | last.message | fromjson'
echo =============

echo =====10-1=====
kubectl get pods -n monitoring -o wide | grep prometheus | awk '{print $7}' | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort -u
echo =============

echo =====10-2=====
GRAFANA_DNS=$(aws elbv2 describe-load-balancers --names grafana-alb --query "LoadBalancers[0].DNSName" --output text); curl -s -u admin:worldpay2026! "http://$GRAFANA_DNS/api/datasources" | jq '.[] | select(.name=="worldpay-prometheus" or .name=="worldpay-logs") | {Name:.name,Type:.type}'
echo =============

echo =====10-3=====
GRAFANA_DNS=$(aws elbv2 describe-load-balancers --names grafana-alb --query "LoadBalancers[0].DNSName" --output text); DASHBOARD_UID=$(curl -s -u admin:worldpay2026! "http://$GRAFANA_DNS/api/search" | jq -r '.[] | select(.title=="worldpay-dashboard") | .uid'); curl -s -u admin:worldpay2026! "http://$GRAFANA_DNS/api/dashboards/uid/$DASHBOARD_UID" | jq '[.dashboard.panels[].title]'
echo =============

echo =====10-4=====
echo manual
echo =============

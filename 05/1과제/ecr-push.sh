#!/bin/bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

# Grafana
aws ecr create-repository --repository-name grafana --region $REGION 2>/dev/null
docker pull grafana/grafana:12.3.1
docker tag grafana/grafana:12.3.1 $REGISTRY/grafana:12.3.1
docker push $REGISTRY/grafana:12.3.1

# Fluent Bit
aws ecr create-repository --repository-name aws-for-fluent-bit --region $REGION 2>/dev/null
docker pull amazon/aws-for-fluent-bit:latest
docker tag amazon/aws-for-fluent-bit:latest $REGISTRY/aws-for-fluent-bit:latest
docker push $REGISTRY/aws-for-fluent-bit:latest

# AWS Load Balancer Controller
aws ecr create-repository --repository-name aws-load-balancer-controller --region $REGION 2>/dev/null
docker pull public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0
docker tag public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0 $REGISTRY/aws-load-balancer-controller:v3.4.0
docker push $REGISTRY/aws-load-balancer-controller:v3.4.0

# Bootstrap container (hostname override)
aws ecr create-repository --repository-name bottlerocket-bootstrap --region $REGION 2>/dev/null
docker build -t $REGISTRY/bottlerocket-bootstrap:latest ./bootstrap-container/
docker push $REGISTRY/bottlerocket-bootstrap:latest

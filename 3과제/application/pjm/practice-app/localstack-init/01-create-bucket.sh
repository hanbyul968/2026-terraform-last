#!/bin/bash
awslocal s3 mb s3://apdev-product-images --region ap-northeast-2
awslocal s3api put-bucket-cors --bucket apdev-product-images --cors-configuration '{
  "CORSRules": [{"AllowedMethods": ["GET", "PUT", "POST"], "AllowedOrigins": ["*"], "AllowedHeaders": ["*"]}]
}'
echo "[localstack-init] bucket apdev-product-images ready"

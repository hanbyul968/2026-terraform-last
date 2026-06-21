#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-2}"
TABLE_NAME="${TABLE_NAME:-nosql-products}"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

cat > "$TMP_FILE" <<JSON
{
  "$TABLE_NAME": [
    {"PutRequest":{"Item":{"product_id":{"S":"P001"},"category":{"S":"Electronics"},"price":{"N":"100"},"name":{"S":"Wireless Mouse"},"stock":{"N":"50"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P002"},"category":{"S":"Electronics"},"price":{"N":"130"},"name":{"S":"USB Keyboard"},"stock":{"N":"35"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P003"},"category":{"S":"Electronics"},"price":{"N":"220"},"name":{"S":"HD Monitor"},"stock":{"N":"18"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P004"},"category":{"S":"Electronics"},"price":{"N":"300"},"name":{"S":"Bluetooth Speaker"},"stock":{"N":"28"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P005"},"category":{"S":"Electronics"},"price":{"N":"450"},"name":{"S":"Tablet"},"stock":{"N":"12"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P006"},"category":{"S":"Books"},"price":{"N":"15"},"name":{"S":"Cloud Basics"},"stock":{"N":"80"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P007"},"category":{"S":"Books"},"price":{"N":"22"},"name":{"S":"Serverless Guide"},"stock":{"N":"60"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P008"},"category":{"S":"Books"},"price":{"N":"35"},"name":{"S":"Database Design"},"stock":{"N":"44"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P009"},"category":{"S":"Books"},"price":{"N":"45"},"name":{"S":"Networking Handbook"},"stock":{"N":"38"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P010"},"category":{"S":"Books"},"price":{"N":"55"},"name":{"S":"AWS Practice"},"stock":{"N":"26"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P011"},"category":{"S":"Home"},"price":{"N":"25"},"name":{"S":"Desk Lamp"},"stock":{"N":"70"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P012"},"category":{"S":"Home"},"price":{"N":"40"},"name":{"S":"Storage Box"},"stock":{"N":"58"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P013"},"category":{"S":"Home"},"price":{"N":"65"},"name":{"S":"Office Chair"},"stock":{"N":"24"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P014"},"category":{"S":"Home"},"price":{"N":"90"},"name":{"S":"Standing Desk Mat"},"stock":{"N":"32"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P015"},"category":{"S":"Home"},"price":{"N":"150"},"name":{"S":"Air Purifier"},"stock":{"N":"14"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P016"},"category":{"S":"Sports"},"price":{"N":"18"},"name":{"S":"Water Bottle"},"stock":{"N":"100"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P017"},"category":{"S":"Sports"},"price":{"N":"30"},"name":{"S":"Yoga Mat"},"stock":{"N":"66"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P018"},"category":{"S":"Sports"},"price":{"N":"75"},"name":{"S":"Running Shoes"},"stock":{"N":"22"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P019"},"category":{"S":"Sports"},"price":{"N":"120"},"name":{"S":"Smart Watch"},"stock":{"N":"16"}}}},
    {"PutRequest":{"Item":{"product_id":{"S":"P020"},"category":{"S":"Sports"},"price":{"N":"180"},"name":{"S":"Bike Helmet"},"stock":{"N":"20"}}}}
  ]
}
JSON

RESPONSE="$(aws dynamodb batch-write-item --request-items "file://$TMP_FILE" --region "$REGION")"
UNPROCESSED_COUNT="$(python3 - "$RESPONSE" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(sum(len(v) for v in data.get("UnprocessedItems", {}).values()))
PY
)"

SUCCESS_COUNT=$((20 - UNPROCESSED_COUNT))
echo "success ${SUCCESS_COUNT} / fail ${UNPROCESSED_COUNT}"

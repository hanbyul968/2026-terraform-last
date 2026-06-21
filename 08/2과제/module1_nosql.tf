# =============================================================================
# Module 1. NoSQL (DynamoDB)  |  Region: ap-northeast-2
#  - 테이블 nosql-products : PK product_id(S), SK category(S), On-Demand
#  - GSI category-price-index : HASH category(S), RANGE price(N), Projection ALL
#  - Stream: NEW_AND_OLD_IMAGES
#  - 샘플 데이터 20건 저장
#  - ~/result.json 생성 (query.sh electronics 결과)
# =============================================================================

resource "aws_dynamodb_table" "products" {
  provider = aws.seoul

  name         = "nosql-products"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "product_id"
  range_key    = "category"

  attribute {
    name = "product_id"
    type = "S"
  }
  attribute {
    name = "category"
    type = "S"
  }
  attribute {
    name = "price"
    type = "N"
  }

  global_secondary_index {
    name            = "category-price-index"
    hash_key        = "category"
    range_key       = "price"
    projection_type = "ALL"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = {
    Module = "NoSQL"
  }
}

# ---- 샘플 상품 데이터 20건 (insert.sh와 동일) ----
locals {
  nosql_products = [
    { product_id = "P001", category = "Electronics", price = 100, name = "Wireless Mouse", stock = 50 },
    { product_id = "P002", category = "Electronics", price = 130, name = "USB Keyboard", stock = 35 },
    { product_id = "P003", category = "Electronics", price = 220, name = "HD Monitor", stock = 18 },
    { product_id = "P004", category = "Electronics", price = 300, name = "Bluetooth Speaker", stock = 28 },
    { product_id = "P005", category = "Electronics", price = 450, name = "Tablet", stock = 12 },
    { product_id = "P006", category = "Books", price = 15, name = "Cloud Basics", stock = 80 },
    { product_id = "P007", category = "Books", price = 22, name = "Serverless Guide", stock = 60 },
    { product_id = "P008", category = "Books", price = 35, name = "Database Design", stock = 44 },
    { product_id = "P009", category = "Books", price = 45, name = "Networking Handbook", stock = 38 },
    { product_id = "P010", category = "Books", price = 55, name = "AWS Practice", stock = 26 },
    { product_id = "P011", category = "Home", price = 25, name = "Desk Lamp", stock = 70 },
    { product_id = "P012", category = "Home", price = 40, name = "Storage Box", stock = 58 },
    { product_id = "P013", category = "Home", price = 65, name = "Office Chair", stock = 24 },
    { product_id = "P014", category = "Home", price = 90, name = "Standing Desk Mat", stock = 32 },
    { product_id = "P015", category = "Home", price = 150, name = "Air Purifier", stock = 14 },
    { product_id = "P016", category = "Sports", price = 18, name = "Water Bottle", stock = 100 },
    { product_id = "P017", category = "Sports", price = 30, name = "Yoga Mat", stock = 66 },
    { product_id = "P018", category = "Sports", price = 75, name = "Running Shoes", stock = 22 },
    { product_id = "P019", category = "Sports", price = 120, name = "Smart Watch", stock = 16 },
    { product_id = "P020", category = "Sports", price = 180, name = "Bike Helmet", stock = 20 },
  ]
}

resource "aws_dynamodb_table_item" "products" {
  provider = aws.seoul
  for_each = { for p in local.nosql_products : p.product_id => p }

  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key
  range_key  = aws_dynamodb_table.products.range_key

  item = jsonencode({
    product_id = { S = each.value.product_id }
    category   = { S = each.value.category }
    price      = { N = tostring(each.value.price) }
    name       = { S = each.value.name }
    stock      = { N = tostring(each.value.stock) }
  })
}

# ---- ~/result.json 생성 안내 ----
# 채점 [1-5]는 CloudShell의 ~/result.json 을 확인한다.
# Terraform이 데이터 20건을 삽입한 뒤, 아래 명령으로 result.json을 생성한다.
# (aws CLI + python3 가 PATH에 있는 환경, 예: CloudShell 에서 실행)
#
#   bash files/nosql/query.sh electronics
#   cat ~/result.json
#
# local-exec 자동화는 실행 환경(PATH의 aws 유무)에 의존하므로 수동 실행을 권장한다.

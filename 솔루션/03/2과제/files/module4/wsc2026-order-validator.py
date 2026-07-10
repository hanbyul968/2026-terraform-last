"""
wsc2026-order-validator / Runtime: python3.13 / Region: ap-southeast-1

단일 주문 객체를 입력받아 검증한다.
  - order_id 는 "ORD-" 로 시작
  - product_id 는 빈 문자열이 아님
  - quantity >= 1
  - unit_price > 0
  - payment_method 는 CARD 또는 BANK_TRANSFER

통과: {"valid": true,  "order": {...}, "errors": [],   "expires_at": <epoch>}
실패: {"valid": false, "order": {...}, "errors": [...], "expires_at": <epoch>}

expires_at 은 Step Functions 의 RecordResult 에서 History 테이블 TTL 값으로 쓰기 위해
매 호출마다 함께 반환한다 (현재 + 30일 Unix timestamp).
ASL 에는 현재 epoch 을 구하는 내장 함수가 없어 Lambda 가 대신 계산한다.
"""

import time

VALID_PAYMENT_METHODS = {"CARD", "BANK_TRANSFER"}
TTL_DAYS = 30


def lambda_handler(event, context):
    order = event if isinstance(event, dict) else {}
    errors = []

    order_id = order.get("order_id", "")
    if not isinstance(order_id, str) or not order_id.startswith("ORD-"):
        errors.append("order_id must start with 'ORD-'")

    product_id = order.get("product_id", "")
    if not isinstance(product_id, str) or product_id.strip() == "":
        errors.append("product_id must not be empty")

    quantity = order.get("quantity")
    if not isinstance(quantity, int) or isinstance(quantity, bool) or quantity < 1:
        errors.append("quantity must be >= 1")

    unit_price = order.get("unit_price")
    if not isinstance(unit_price, (int, float)) or isinstance(unit_price, bool) or unit_price <= 0:
        errors.append("unit_price must be > 0")

    payment_method = order.get("payment_method")
    if payment_method not in VALID_PAYMENT_METHODS:
        errors.append("payment_method must be CARD or BANK_TRANSFER")

    return {
        "valid": len(errors) == 0,
        "order": order,
        "errors": errors,
        "expires_at": int(time.time()) + TTL_DAYS * 24 * 60 * 60,
    }

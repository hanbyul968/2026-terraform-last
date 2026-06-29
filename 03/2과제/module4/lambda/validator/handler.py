# -*- coding: utf-8 -*-
# wsc2026-order-validator  (python3.13)
# 단일 주문 객체를 입력받아 유효성 검사.
#   - order_id 가 "ORD-" 접두사로 시작
#   - product_id 가 빈 문자열이 아님
#   - quantity 가 1 이상
#   - unit_price 가 0 보다 큼
#   - payment_method 가 "CARD" 또는 "BANK_TRANSFER" 중 하나
# 통과: {"valid": true, "order": {...}}
# 실패: {"valid": false, "order": {...}, "errors": [...]}


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def lambda_handler(event, context):
    order = event if isinstance(event, dict) else {}
    errors = []

    order_id = order.get("order_id", "")
    if not (isinstance(order_id, str) and order_id.startswith("ORD-")):
        errors.append("order_id must start with 'ORD-'")

    product_id = order.get("product_id", "")
    if not (isinstance(product_id, str) and product_id != ""):
        errors.append("product_id must not be empty")

    quantity = order.get("quantity", 0)
    if not (_is_number(quantity) and quantity >= 1):
        errors.append("quantity must be >= 1")

    unit_price = order.get("unit_price", 0)
    if not (_is_number(unit_price) and unit_price > 0):
        errors.append("unit_price must be > 0")

    payment_method = order.get("payment_method", "")
    if payment_method not in ("CARD", "BANK_TRANSFER"):
        errors.append("payment_method must be 'CARD' or 'BANK_TRANSFER'")

    if errors:
        return {"valid": False, "order": order, "errors": errors}
    return {"valid": True, "order": order}

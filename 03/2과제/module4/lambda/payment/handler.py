# -*- coding: utf-8 -*-
# wsc2026-payment-processor  (python3.13)
# 검증 통과 주문(order 객체)을 입력받아 결제 처리.
#   - total_amount = quantity * unit_price
#   - total_usd = total_amount / 1350 (소수점 2자리 반올림, 1 USD = 1350 KRW 고정)
#   - payment_status = "APPROVED"
#   - processed_at = ISO 8601
#   - expires_at = 현재 + 30일 Unix timestamp (history TTL 용)
import datetime

USD_RATE = 1350  # 1 USD = 1350 KRW (고정 환율)


def lambda_handler(event, context):
    # State machine 이 Payload.$ = "$.order" 로 주문 객체를 직접 전달한다.
    order = dict(event) if isinstance(event, dict) else {}

    quantity = order.get("quantity", 0)
    unit_price = order.get("unit_price", 0)

    total_amount = quantity * unit_price
    order["total_amount"] = total_amount
    order["total_usd"] = round(total_amount / USD_RATE, 2)
    order["payment_status"] = "APPROVED"

    now = datetime.datetime.now(datetime.timezone.utc)
    order["processed_at"] = now.isoformat()
    if not order.get("ordered_at"):
        order["ordered_at"] = order["processed_at"]
    order["expires_at"] = int(now.timestamp()) + 30 * 24 * 3600

    return order

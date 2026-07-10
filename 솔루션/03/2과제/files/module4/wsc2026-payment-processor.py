"""
wsc2026-payment-processor / Runtime: python3.13 / Region: ap-southeast-1

검증을 통과한 주문을 입력받아 결제를 처리한다.
  - total_amount = quantity * unit_price
  - total_usd    = total_amount / 1350  (환율 고정, 소수점 2자리 반올림)
  - payment_status = "APPROVED"
  - processed_at   = ISO 8601

입력은 validator 의 출력({"valid":..., "order":{...}}) 또는 주문 객체 그 자체를 모두 허용한다.
"""

from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

USD_KRW_RATE = Decimal("1350")


def lambda_handler(event, context):
    order = event.get("order", event)

    quantity = int(order["quantity"])
    unit_price = Decimal(str(order["unit_price"]))

    total_amount = unit_price * quantity
    total_usd = (total_amount / USD_KRW_RATE).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP
    )

    processed = dict(order)
    processed["total_amount"] = int(total_amount) if total_amount == total_amount.to_integral_value() else float(total_amount)
    processed["total_usd"] = float(total_usd)
    processed["payment_status"] = "APPROVED"
    processed["processed_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    return processed

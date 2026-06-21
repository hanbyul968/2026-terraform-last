#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-2}"
TABLE_NAME="${TABLE_NAME:-nosql-products}"
RAW_CATEGORY="${1:-Electronics}"
CATEGORY="$(python3 - "$RAW_CATEGORY" <<'PY'
import sys
value = sys.argv[1].strip()
aliases = {
    "electronics": "Electronics",
    "books": "Books",
    "home": "Home",
    "sports": "Sports",
}
print(aliases.get(value.lower(), value))
PY
)"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --index-name category-price-index \
  --key-condition-expression "category = :category" \
  --expression-attribute-values "{\":category\":{\"S\":\"$CATEGORY\"}}" \
  --scan-index-forward \
  --region "$REGION" \
  --output json > "$TMP_FILE"

python3 - "$TMP_FILE" "$HOME/result.json" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

items = []
for item in data.get("Items", []):
    converted = {}
    for key, value in item.items():
        if "S" in value:
            converted[key] = value["S"]
        elif "N" in value:
            number = value["N"]
            converted[key] = int(number) if number.isdigit() else float(number)
    items.append(converted)

with open(dst, "w", encoding="utf-8") as f:
    json.dump(items, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"saved {len(items)} items to {dst}")
PY

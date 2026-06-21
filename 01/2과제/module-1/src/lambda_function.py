import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ.get("TABLE_NAME", "wsc2026-api-storage")
table = dynamodb.Table(TABLE_NAME)


def _response(status_code, body):
    """Build an API Gateway proxy compatible response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _put_item(item):
    table.put_item(Item=item)


def _get_item(item_id):
    result = table.get_item(Key={"id": item_id})
    return result.get("Item")


def handler(event, context):
    """
    Handles two invocation styles:

    1. API Gateway proxy integration:
       - event['httpMethod'] = 'POST' | 'GET'
       - event['body']       = JSON string (POST)
       - event['queryStringParameters'] = {'id': '...'} (GET)

    2. Direct Lambda invoke (e.g. grading script):
       - payload like {"method": "GET", "id": "lambda-chk-999"}
       - payload like {"method": "POST", "id": "x", "name": "y", "team": "z"}
    """
    event = event or {}

    # Determine HTTP method. API GW uses 'httpMethod'; direct invoke uses 'method'.
    method = event.get("httpMethod") or event.get("method")
    if method:
        method = method.upper()

    try:
        # ---------- Direct Lambda invoke (no httpMethod) ----------
        if "httpMethod" not in event:
            if method == "POST":
                item = {
                    "id": event["id"],
                    "name": event.get("name"),
                    "team": event.get("team"),
                }
                _put_item(item)
                return _response(
                    200,
                    {"message": "Item created successfully", "id": item["id"]},
                )

            # Default direct invoke behavior is GET
            item_id = event.get("id")
            if not item_id:
                return _response(400, {"message": "Missing 'id'"})
            item = _get_item(item_id)
            if item is None:
                return _response(404, {"message": "Item not found", "id": item_id})
            return _response(200, item)

        # ---------- API Gateway proxy integration ----------
        if method == "POST":
            raw_body = event.get("body") or "{}"
            if isinstance(raw_body, (dict, list)):
                payload = raw_body
            else:
                payload = json.loads(raw_body)

            item = {
                "id": payload["id"],
                "name": payload.get("name"),
                "team": payload.get("team"),
            }
            _put_item(item)
            return _response(
                200,
                {"message": "Item created successfully", "id": item["id"]},
            )

        if method == "GET":
            params = event.get("queryStringParameters") or {}
            item_id = params.get("id")
            if not item_id:
                return _response(400, {"message": "Missing 'id' query parameter"})
            item = _get_item(item_id)
            if item is None:
                return _response(404, {"message": "Item not found", "id": item_id})
            return _response(200, item)

        return _response(405, {"message": "Method not allowed: {}".format(method)})

    except KeyError as e:
        return _response(400, {"message": "Missing required field: {}".format(str(e))})
    except Exception as e:  # noqa: BLE001
        return _response(500, {"message": "Internal server error", "error": str(e)})

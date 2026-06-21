import json, boto3, os
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['TABLE_NAME'])

class DecimalEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            return str(o)
        return super().default(o)

def handler(event, context):
    # Support both API Gateway proxy and direct invoke
    method = event.get('httpMethod') or event.get('method', 'GET')
    
    if method == 'POST':
        body = event.get('body')
        if isinstance(body, str):
            body = json.loads(body)
        elif body is None:
            body = {k: event[k] for k in ('id','name','team') if k in event}
        table.put_item(Item=body)
        return respond(200, {"message": "Item created successfully", "id": body['id']})
    
    elif method == 'GET':
        qsp = event.get('queryStringParameters') or {}
        item_id = qsp.get('id') or event.get('id')
        if not item_id:
            return respond(400, {"message": "Missing id"})
        resp = table.get_item(Key={'id': item_id})
        item = resp.get('Item')
        if item:
            return respond(200, item)
        return respond(404, {"message": "Item not found"})
    
    return respond(400, {"message": "Unsupported method"})

def respond(code, body):
    return {
        'statusCode': code,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(body, cls=DecimalEncoder)
    }

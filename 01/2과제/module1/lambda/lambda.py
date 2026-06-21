import json
import boto3
import os

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['TABLE_NAME'])

def handler(event, context):
    method = event.get('httpMethod') or event.get('method')
    
    if method == 'POST':
        body = json.loads(event['body']) if isinstance(event.get('body'), str) else event.get('body') or event
        item = {}
        for k, v in body.items():
            if k not in ['httpMethod', 'method']:
                item[k] = v
        table.put_item(Item=item)
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'message': 'Item created successfully', 'id': item['id']})
        }
    elif method == 'GET':
        item_id = None
        if event.get('queryStringParameters'):
            item_id = event['queryStringParameters'].get('id')
        if not item_id:
            item_id = event.get('id')
        response = table.get_item(Key={'id': item_id})
        item = response.get('Item', {})
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps(item)
        }

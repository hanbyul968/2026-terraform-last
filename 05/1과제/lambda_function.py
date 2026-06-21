import json
import boto3
import os

dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")
table = dynamodb.Table(os.environ.get("TABLE_NAME", "books"))


def put_metric(client_id):
    cloudwatch.put_metric_data(
        Namespace="BookReservation",
        MetricData=[{
            "MetricName": "InvocationCount",
            "Dimensions": [{"Name": "client_id", "Value": client_id}],
            "Value": 1,
            "Unit": "Count",
        }],
    )


def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}
    client_id = params.get("client_id")

    if client_id:
        put_metric(client_id)
        resp = table.query(
            IndexName="client_id-index",
            KeyConditionExpression=boto3.dynamodb.conditions.Key("client_id").eq(client_id),
        )
    else:
        put_metric("ALL")
        resp = table.scan()

    items = [
        {"username": i["username"], "email": i["email"], "concert_name": i["concert_name"]}
        for i in resp.get("Items", [])
    ]

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(items),
    }

import json
import os

import boto3

rds_data = boto3.client("rds-data")


def execute(sql, parameters=None):
    return rds_data.execute_statement(
        resourceArn=os.environ["CLUSTER_ARN"],
        secretArn=os.environ["SECRET_ARN"],
        database=os.environ.get("DB_NAME", "appdb"),
        sql=sql,
        parameters=parameters or [],
        includeResultMetadata=True,
    )


def field_value(field):
    if "stringValue" in field:
        return field["stringValue"]
    if "longValue" in field:
        return field["longValue"]
    if "doubleValue" in field:
        return field["doubleValue"]
    if field.get("isNull"):
        return None
    return field


def lambda_handler(event, context):
    execute(
        """
        CREATE TABLE IF NOT EXISTS products (
            product_id VARCHAR(20) PRIMARY KEY,
            category VARCHAR(50) NOT NULL,
            price INT NOT NULL
        )
        """
    )

    execute(
        """
        INSERT INTO products (product_id, category, price)
        VALUES (:product_id, :category, :price)
        ON DUPLICATE KEY UPDATE
            category = VALUES(category),
            price = VALUES(price)
        """,
        [
            {"name": "product_id", "value": {"stringValue": "P001"}},
            {"name": "category", "value": {"stringValue": "Electronics"}},
            {"name": "price", "value": {"longValue": 100}},
        ],
    )

    result = execute(
        """
        SELECT product_id, category, price
        FROM products
        ORDER BY product_id
        """
    )

    columns = [col["name"] for col in result.get("columnMetadata", [])]
    rows = []
    for record in result.get("records", []):
        rows.append({columns[i]: field_value(record[i]) for i in range(len(columns))})

    return {
        "statusCode": 200,
        "body": json.dumps(rows, ensure_ascii=False),
    }

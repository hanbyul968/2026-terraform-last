import json
import os
import datetime
import pymysql

DB_HOST = os.environ.get('DB_HOST')
DB_USER = os.environ.get('DB_USER', 'admin')
DB_PASSWORD = os.environ.get('DB_PASSWORD')
DB_NAME = 'data'

def get_connection(database=None):
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=database,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10
    )

def ensure_schema():
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("CREATE DATABASE IF NOT EXISTS data")
        conn.commit()
    finally:
        conn.close()
    conn = get_connection(DB_NAME)
    try:
        with conn.cursor() as cur:
            cur.execute("""CREATE TABLE IF NOT EXISTS users (
                id INT AUTO_INCREMENT PRIMARY KEY,
                username VARCHAR(50) NOT NULL UNIQUE,
                role VARCHAR(20) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
        conn.commit()
    finally:
        conn.close()

_initialized = False

def lambda_handler(event, context):
    global _initialized
    if not _initialized:
        ensure_schema()
        _initialized = True

    action = event.get('action')
    username = event.get('username')
    role = event.get('role')
    try:
        conn = get_connection(DB_NAME)
        with conn.cursor() as cursor:
            if action == 'create':
                cursor.execute("INSERT INTO users (username, role) VALUES (%s, %s)", (username, role))
                conn.commit()
                return {"statusCode": 201, "body": json.dumps({"message": f"User {username} created successfully"}, ensure_ascii=False)}
            elif action == 'read':
                cursor.execute("SELECT username, role, created_at FROM users WHERE username = %s", (username,))
                result = cursor.fetchone()
                if result and result.get('created_at'):
                    if isinstance(result['created_at'], (datetime.datetime, datetime.date)):
                        result['created_at'] = result['created_at'].strftime('%Y-%m-%d %H:%M:%S')
                return {"statusCode": 200, "body": json.dumps(result, ensure_ascii=False)}
    except Exception as e:
        return {"statusCode": 500, "body": json.dumps({"error": str(e)}, ensure_ascii=False)}
    finally:
        if 'conn' in locals() and conn.open:
            conn.close()

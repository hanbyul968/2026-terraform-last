%flink.ssql

-- 1) Kinesis Data Stream 을 Flink 테이블로 매핑
DROP TABLE IF EXISTS order_stream;

CREATE TABLE order_stream (
    order_id     STRING,
    product_name STRING,
    price        BIGINT,
    quantity     INT,
    event_time   TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector'                    = 'kinesis',
    'stream'                       = 'wsc2026-order-stream',
    'aws.region'                   = 'ap-northeast-2',
    'scan.stream.initpos'          = 'LATEST',
    'format'                       = 'json',
    'json.timestamp-format.standard' = 'SQL'
);


%flink.ssql(type=update)

-- 2) 최근 1분간 총 주문 수
SELECT COUNT(*) as order_count
  FROM order_stream
 WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;


%flink.ssql(type=update)

-- 3) 상품별 누적 매출
SELECT product_name, SUM(price * quantity) as total_revenue
  FROM order_stream
 GROUP BY product_name;

%flink.ssql
DROP TEMPORARY TABLE IF EXISTS order_logs;
DROP TEMPORARY TABLE IF EXISTS sink_error_stats;
DROP TEMPORARY TABLE IF EXISTS sink_high_latency;
DROP TEMPORARY TABLE IF EXISTS sink_anomaly;

CREATE TEMPORARY TABLE order_logs (
  order_id STRING, user_id STRING, cart_age_seconds INT,
  status_code INT, latency_ms INT, event_time BIGINT,
  ts AS TO_TIMESTAMP_LTZ(event_time,3),
  WATERMARK FOR ts AS ts
) WITH ('connector'='kafka','topic'='order-logs',
  'properties.bootstrap.servers'='gj2026-data-nlb-700d5c3e0058c5ce.elb.ap-southeast-1.amazonaws.com:9094',
  'properties.group.id'='flink-src','scan.startup.mode'='earliest-offset',
  'format'='json','json.ignore-parse-errors'='true');

CREATE TEMPORARY TABLE sink_error_stats (
  window_start TIMESTAMP(3), window_end TIMESTAMP(3),
  total_count BIGINT, error_count BIGINT, error_rate DOUBLE, avg_latency_ms DOUBLE
) WITH ('connector'='kafka','topic'='error-stats',
  'properties.bootstrap.servers'='gj2026-data-nlb-700d5c3e0058c5ce.elb.ap-southeast-1.amazonaws.com:9094','format'='json');

CREATE TEMPORARY TABLE sink_high_latency (
  order_id STRING, user_id STRING, latency_ms INT,
  avg_latency_ms DOUBLE, proc_time STRING, is_anomaly INT
) WITH ('connector'='kafka','topic'='high-latency',
  'properties.bootstrap.servers'='gj2026-data-nlb-700d5c3e0058c5ce.elb.ap-southeast-1.amazonaws.com:9094','format'='json');

CREATE TEMPORARY TABLE sink_anomaly (
  user_id STRING, order_count BIGINT, rate_limit_count BIGINT,
  bot_suspected_count BIGINT, anomaly_type STRING,
  window_start TIMESTAMP(3), window_end TIMESTAMP(3)
) WITH ('connector'='kafka','topic'='anomaly',
  'properties.bootstrap.servers'='gj2026-data-nlb-700d5c3e0058c5ce.elb.ap-southeast-1.amazonaws.com:9094','format'='json');

BEGIN STATEMENT SET;
-- Query 1: 에러 비율 (2분 HOP, 30초 슬라이드)
INSERT INTO sink_error_stats
SELECT HOP_START(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       HOP_END(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       COUNT(*), SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END)*100.0/COUNT(*),2),
       ROUND(AVG(CAST(latency_ms AS DOUBLE)),2)
FROM order_logs GROUP BY HOP(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE);
-- Query 2: 고지연 (유저별 최근 100건 평균 초과)
INSERT INTO sink_high_latency
SELECT order_id,user_id,latency_ms,ROUND(avg_l,2),
  DATE_FORMAT(ts,'yyyy-MM-dd HH:mm:ss.SSS'),
  CASE WHEN latency_ms>500 THEN 1 ELSE 0 END
FROM (SELECT order_id,user_id,latency_ms,ts,
  AVG(CAST(latency_ms AS DOUBLE)) OVER (PARTITION BY user_id ORDER BY ts ROWS BETWEEN 99 PRECEDING AND CURRENT ROW) AS avg_l
  FROM order_logs) WHERE latency_ms>avg_l;
-- Query 3: 이상 사용자 (2분 HOP, 우선순위 분류)
INSERT INTO sink_anomaly
SELECT user_id,order_count,rate_limit_count,bot_suspected_count,
  CASE WHEN bot_suspected_count*100.0/order_count>80 THEN 'BOT_SUSPECTED'
       WHEN rate_limit_count*100.0/order_count>50 THEN 'RATE_LIMITED'
       WHEN order_count>150 THEN 'EXCESSIVE_ORDER' END,
  window_start,window_end
FROM (SELECT user_id,
  HOP_START(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE) AS window_start,
  HOP_END(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE) AS window_end,
  COUNT(*) AS order_count,
  SUM(CASE WHEN status_code=429 THEN 1 ELSE 0 END) AS rate_limit_count,
  SUM(CASE WHEN cart_age_seconds<3 THEN 1 ELSE 0 END) AS bot_suspected_count
  FROM order_logs GROUP BY user_id,HOP(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE))
WHERE bot_suspected_count*100.0/order_count>80 OR rate_limit_count*100.0/order_count>50 OR order_count>150;
END;

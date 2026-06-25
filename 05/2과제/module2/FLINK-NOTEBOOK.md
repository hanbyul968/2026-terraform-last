# Module 2 — Flink(Zeppelin) 노트북 실행 가이드 (2-3 / 2-4 / 2-5)

`terraform apply`가 해주는 것: Kafka EC2 + 토픽 + app.py(2-1/2-2) + NLB + Glue DB + **Zeppelin Studio 앱 생성·자동 시작**.
**사람이 하는 것: 노트북에 아래 SQL 2덩이 붙여넣고 실행하는 것뿐.** (AWS엔 노트북 SQL을 자동 주입하는 API가 없음)

---

## 0. 사전 확인

```bash
# Studio 앱이 RUNNING 인지 (RUNNING 아니면 몇 분 대기)
aws kinesisanalyticsv2 describe-application --application-name gj2026-data-zeppelin \
  --region ap-southeast-1 --query "ApplicationDetail.ApplicationStatus" --output text

# Kafka 부트스트랩(NLB DNS) 확인 — SQL의 bootstrap.servers 에 들어갈 값
aws elbv2 describe-load-balancers --names gj2026-data-nlb --region ap-southeast-1 \
  --query 'LoadBalancers[0].DNSName' --output text
```
> READY 상태면 시작: `aws kinesisanalyticsv2 start-application --application-name gj2026-data-zeppelin --region ap-southeast-1`

---

## 1. 노트북 열기

1. AWS 콘솔 → **Managed Service for Apache Flink** (리전 **ap-southeast-1**)
2. 좌측 **Studio notebooks** → `gj2026-data-zeppelin`
3. 상태 **RUNNING** 확인 → **Open in Apache Zeppelin**
4. **Create new note** (또는 기존 노트) → 셀에 아래 SQL 붙여넣기 → 각 셀 **Shift+Enter**

> 아래 SQL의 `<NLB_DNS>` 를 위 0번에서 확인한 NLB DNS로 **3덩이 전부** 바꿔야 합니다.
> (현재 값 예: `gj2026-data-nlb-880d23256481822d.elb.ap-southeast-1.amazonaws.com`)

---

## 2. 첫 번째 셀 — 소스/싱크 테이블 DDL

```sql
%flink.ssql
DROP TABLE IF EXISTS order_logs;
CREATE TABLE order_logs (
  order_id STRING, user_id STRING, cart_age_seconds INT,
  status_code INT, latency_ms INT, event_time BIGINT,
  ts AS TO_TIMESTAMP_LTZ(event_time, 3),
  WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH (
  'connector'='kafka', 'topic'='order-logs',
  'properties.bootstrap.servers'='<NLB_DNS>:9094',
  'scan.startup.mode'='earliest-offset',
  'format'='json','json.ignore-parse-errors'='true'
);

DROP TABLE IF EXISTS sink_error_stats;
CREATE TABLE sink_error_stats (
  window_start TIMESTAMP(3), window_end TIMESTAMP(3),
  total_count BIGINT, error_count BIGINT, error_rate DOUBLE, avg_latency_ms DOUBLE
) WITH ('connector'='kafka','topic'='error-stats',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');

DROP TABLE IF EXISTS sink_high_latency;
CREATE TABLE sink_high_latency (
  order_id STRING, user_id STRING, latency_ms INT,
  avg_latency_ms DOUBLE, proc_time STRING, is_anomaly INT
) WITH ('connector'='kafka','topic'='high-latency',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');

DROP TABLE IF EXISTS sink_anomaly;
CREATE TABLE sink_anomaly (
  user_id STRING, order_count BIGINT, rate_limit_count BIGINT,
  bot_suspected_count BIGINT, anomaly_type STRING,
  window_start TIMESTAMP(3), window_end TIMESTAMP(3)
) WITH ('connector'='kafka','topic'='anomaly',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');
```

---

## 3. 두 번째 셀 — 3개 쿼리 단일 잡 (STATEMENT SET)

```sql
%flink.ssql
EXECUTE STATEMENT SET
BEGIN
-- Query 1: 에러 비율 (2분 HOP, 30초 슬라이드)
INSERT INTO sink_error_stats
SELECT HOP_START(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       HOP_END(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       COUNT(*), SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END)*100.0/COUNT(*),2),
       ROUND(AVG(CAST(latency_ms AS DOUBLE)),2)
FROM order_logs
GROUP BY HOP(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE);

-- Query 2: 고지연 (유저별 최근 100건 평균 초과)
INSERT INTO sink_high_latency
SELECT order_id,user_id,latency_ms, ROUND(avg_l,2),
  DATE_FORMAT(ts,'yyyy-MM-dd HH:mm:ss.SSS'),
  CASE WHEN latency_ms>500 THEN 1 ELSE 0 END
FROM (
  SELECT order_id,user_id,latency_ms,ts,
    AVG(CAST(latency_ms AS DOUBLE)) OVER (
      PARTITION BY user_id ORDER BY ts ROWS BETWEEN 99 PRECEDING AND CURRENT ROW) AS avg_l
  FROM order_logs
) WHERE latency_ms > avg_l;

-- Query 3: 이상 사용자 (2분 HOP, 우선순위 분류)
INSERT INTO sink_anomaly
SELECT user_id,order_count,rate_limit_count,bot_suspected_count,
  CASE WHEN bot_suspected_count*100.0/order_count>80 THEN 'BOT_SUSPECTED'
       WHEN rate_limit_count*100.0/order_count>50 THEN 'RATE_LIMITED'
       WHEN order_count>150 THEN 'EXCESSIVE_ORDER' END,
  window_start,window_end
FROM (
  SELECT user_id,
    HOP_START(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE) AS window_start,
    HOP_END(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE) AS window_end,
    COUNT(*) AS order_count,
    SUM(CASE WHEN status_code=429 THEN 1 ELSE 0 END) AS rate_limit_count,
    SUM(CASE WHEN cart_age_seconds<3 THEN 1 ELSE 0 END) AS bot_suspected_count
  FROM order_logs
  GROUP BY user_id,HOP(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE)
) WHERE bot_suspected_count*100.0/order_count>80
     OR rate_limit_count*100.0/order_count>50
     OR order_count>150;
END;
```

> 이 셀을 실행하면 Flink 잡이 떠서 계속 돌아갑니다. (Zeppelin 상단에 잡이 RUNNING으로 표시)

---

## 4. 데이터 전송 → 채점

EC2(gj2026-data-ec2)에서:
```bash
# (선택) 토픽 초기화 — 이전에 app.py를 돌린 적 있으면 10000을 넘으므로 리셋
/opt/kafka/bin/kafka-topics.sh --delete --topic order-logs --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic order-logs --partitions 2 --replication-factor 1 --bootstrap-server localhost:9092

# 로그 10000건 생성·전송
python3 /home/ec2-user/app.py

# 30초쯤 후 채점 (error-stats/high-latency/anomaly 토픽 소비)
./mark.sh        # 또는 채점기준표 2-3/2-4/2-5 명령
```

---

## 순서 요약
1. Studio `RUNNING` 확인 → 노트북 열기
2. 2번 셀(DDL) 실행 → 3번 셀(쿼리 잡) 실행
3. EC2에서 `app.py` 1회 (order-logs에 10000건)
4. 30초 후 채점 → 2-3/2-4/2-5 결과 확인

> 예상 출력(예: `error_rate:19.36`, `total_count:9000`)과 숫자가 1~2 차이 나면 윈도우/워터마크/반올림 미세조정이 필요할 수 있습니다.

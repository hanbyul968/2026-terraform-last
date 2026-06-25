# Module 2 — Flink(Zeppelin) 노트북 실행 가이드 (2-3 / 2-4 / 2-5)

`terraform apply`가 해주는 것:
- Kafka EC2 + 토픽 + app.py (2-1/2-2)
- NLB, Glue DB
- **Zeppelin Studio 앱 생성·자동 시작 + Kafka 커넥터(custom artifact) 자동 등록**

**사람이 하는 것: 노트북에 SQL 1셀 붙여넣고 실행 → EC2에서 `./mark.sh`.** (AWS엔 노트북 SQL을 자동 주입하는 API가 없어서 이 한 단계만 수동)

---

## 0. 사전 확인 (CloudShell)

```bash
# Studio 앱 RUNNING 확인 (아니면 몇 분 대기 / READY면 start)
aws kinesisanalyticsv2 describe-application --application-name gj2026-data-zeppelin \
  --region ap-southeast-1 --query "ApplicationDetail.ApplicationStatus" --output text

# NLB DNS 확인 — SQL의 bootstrap.servers 값
aws elbv2 describe-load-balancers --names gj2026-data-nlb --region ap-southeast-1 \
  --query 'LoadBalancers[0].DNSName' --output text
```
> READY면 시작: `aws kinesisanalyticsv2 start-application --application-name gj2026-data-zeppelin --region ap-southeast-1`

---

## 1. 노트북 열기

1. AWS 콘솔 → **Managed Service for Apache Flink** (리전 **ap-southeast-1**)
2. **Studio notebooks** → `gj2026-data-zeppelin` → 상태 **RUNNING** → **Open in Apache Zeppelin**
3. **Create new note** → 셀에 아래 SQL 붙여넣기

### ⚠️ 자주 나는 에러 3가지
- **`not found: value DROP` (Scala 에러)** → `%flink.ssql`이 빠져서 Scala로 감. 셀 **첫 줄에 `%flink.ssql`** 필수.
- **`Encountered "%" at line 1`** → `%flink.ssql` 앞에 공백/빈 줄 있음. 첫 글자가 `%`가 되도록.
- **`Unable to create a source ... Table options are 'connector'='kafka'`** → Kafka 커넥터 미인식.
  terraform이 커넥터를 등록했으니, **노트북 Interpreter에서 `flink` restart** 후 다시 실행 (앱을 방금 재시작했으면 세션 캐시 때문).

---

## 2. 한 셀에 전부 (TEMPORARY 테이블 + 3쿼리 STATEMENT SET)

> `<NLB_DNS>` 4곳을 0번에서 확인한 NLB DNS로 바꾸세요.
> `%flink.ssql`은 **셀 맨 첫 줄**. temp 테이블은 `DROP TEMPORARY TABLE`로 지웁니다.

```sql
%flink.ssql
DROP TEMPORARY TABLE IF EXISTS order_logs;
DROP TEMPORARY TABLE IF EXISTS sink_error_stats;
DROP TEMPORARY TABLE IF EXISTS sink_high_latency;
DROP TEMPORARY TABLE IF EXISTS sink_anomaly;

CREATE TEMPORARY TABLE order_logs (
  order_id STRING, user_id STRING, cart_age_seconds INT,
  status_code INT, latency_ms INT, event_time BIGINT,
  ts AS TO_TIMESTAMP_LTZ(event_time,3),
  WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH ('connector'='kafka','topic'='order-logs',
  'properties.bootstrap.servers'='<NLB_DNS>:9094',
  'properties.group.id'='flink-src','scan.startup.mode'='earliest-offset',
  'format'='json','json.ignore-parse-errors'='true');

CREATE TEMPORARY TABLE sink_error_stats (
  window_start TIMESTAMP(3), window_end TIMESTAMP(3),
  total_count BIGINT, error_count BIGINT, error_rate DOUBLE, avg_latency_ms DOUBLE
) WITH ('connector'='kafka','topic'='error-stats',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');

CREATE TEMPORARY TABLE sink_high_latency (
  order_id STRING, user_id STRING, latency_ms INT,
  avg_latency_ms DOUBLE, proc_time STRING, is_anomaly INT
) WITH ('connector'='kafka','topic'='high-latency',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');

CREATE TEMPORARY TABLE sink_anomaly (
  user_id STRING, order_count BIGINT, rate_limit_count BIGINT,
  bot_suspected_count BIGINT, anomaly_type STRING,
  window_start TIMESTAMP(3), window_end TIMESTAMP(3)
) WITH ('connector'='kafka','topic'='anomaly',
  'properties.bootstrap.servers'='<NLB_DNS>:9094','format'='json');

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
```

실행하면 Flink 잡이 떠서 계속 돌아갑니다 (셀에 RUNNING 스피너 / FLINK JOB 링크).

> 소스 확인용(선택): 별도 셀에 `%flink.ssql` + `SELECT * FROM order_logs LIMIT 5;` → 행 나오면 커넥터·연결 정상.

---

## 3. 데이터 + 채점 (EC2)

`mark.sh`가 app.py를 1번 돌려 order-logs에 10000건 보냅니다. **`./mark.sh` 한 번이면 데이터+채점 끝.**

```bash
./mark.sh
```

⚠️ order-logs가 이미 10000 초과로 오염됐으면 리셋 후 다시:
```bash
/opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic order-logs --time -1 | awk -F: '{s+=$NF} END{print s}'   # 10000 확인
/opt/kafka/bin/kafka-topics.sh --delete --topic order-logs --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic order-logs --partitions 2 --replication-factor 1 --bootstrap-server localhost:9092
```

---

## 순서 요약
1. Studio `RUNNING` 확인 (커넥터는 terraform이 등록함)
2. 노트북 열고 → **2번 셀 한 개** 실행 (`%flink.ssql` 첫 줄, `<NLB_DNS>` 교체) → 잡 RUNNING
3. (오염 시만) order-logs 리셋
4. EC2 `./mark.sh` → 2-3/2-4/2-5 결과 확인

> 예상값(`total_count:9000`, `error_rate:19.36` 등)과 숫자 차이 나면 그 출력 주세요 — 윈도우/반올림 맞춰드립니다.

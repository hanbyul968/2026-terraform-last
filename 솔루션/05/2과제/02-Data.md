# Module 2 — Real-time data analytics (ap-southeast-1)

> **리전 ap-southeast-1**

## 구성 요약
```
gj2026-data-ec2 (Kafka KRaft)  ── 9092(내부) / 9094(외부)
        ▲                              │
        │ NLB(TCP 9094)               │
Managed Flink(Zeppelin) ───읽기 order-logs / 쓰기 error-stats,high-latency,anomaly
        └ 메타스토어 = Glue DB real_time_analytics
app.py → order-logs 로 10000건 전송
```

| 항목 | 값 |
|---|---|
| EC2 | `gj2026-data-ec2` (t3.small, AL2023) |
| 토픽 | order-logs(2), error-stats(1), high-latency(1), anomaly(1) |
| NLB | `gj2026-data-nlb` (Internet-facing, TCP 9094) |
| Glue DB | `real_time_analytics` |
| Flink | Managed Service for Apache Flink Studio(Zeppelin) |

---

## 1) Glue Database 생성
**콘솔 → AWS Glue → 데이터베이스 → 데이터베이스 추가**
- 이름: `real_time_analytics` → 생성

---

## 2) EC2 IAM 역할
**IAM → 역할 만들기** → AWS 서비스/EC2 → 권한 `AdministratorAccess`(편의) → 이름 `gj2026-data-ec2-role`
- 역할 상세 → **인스턴스 프로파일**은 EC2 생성 시 자동 연결됨

## 3) Security Group
**VPC → 보안 그룹 → 생성** (Default VPC)
- 이름 `gj2026-data-kafka-sg`
- 인바운드: 22, 9092, 9094 (TCP, 0.0.0.0/0) — 편하게 하려면 모든 트래픽 허용
- 아웃바운드: 전체 허용

## 4) EC2 (Kafka) 생성
**EC2 → 인스턴스 시작**
- 이름: `gj2026-data-ec2`
- AMI: **Amazon Linux 2023** (minimal 말고 표준)
- 유형: t3.small
- 키페어: 없이 진행 가능(접속은 SSM), 또는 키 지정
- 네트워크: Default VPC, **퍼블릭 IP 자동 할당 켜기**
- 보안그룹: `gj2026-data-kafka-sg`
- IAM 인스턴스 프로파일: `gj2026-data-ec2-role`
- **고급 세부정보 → 사용자 데이터**에 아래 붙여넣기 (NLB DNS는 5)에서 만든 뒤 넣거나, 일단 생성 후 접속해서 수동 실행해도 됨)

> ⚠️ `advertised.listeners`의 EXTERNAL에 **NLB DNS**가 필요합니다. NLB를 먼저(5번) 만들고 그 DNS를 아래 `NLB_DNS`에 넣으세요. (순서: NLB 먼저 만들고 EC2 사용자데이터 작성)

```bash
#!/bin/bash
set -x
NLB_DNS="<여기에 NLB DNS>"      # 예: gj2026-data-nlb-xxxx.elb.ap-southeast-1.amazonaws.com

# 배포 app.py (Real-time data analytics 배포파일) 배치 - 반드시 원본 그대로
# CloudShell에서 base64로 넣거나, 아래처럼 S3에서 받아도 됨. 여기선 SSM/scp로 올린다고 가정.
mkdir -p /var/log/app; chown -R ec2-user:ec2-user /var/log/app

dnf install -y java-21-amazon-corretto python3-pip
pip3 install kafka-python

# Kafka 4.0.1 (dlcdn = 빠름)
cd /opt
curl -fsSL -o kafka.tgz "https://dlcdn.apache.org/kafka/4.0.1/kafka_2.13-4.0.1.tgz"
tar -xzf kafka.tgz && ln -s kafka_2.13-4.0.1 kafka && rm kafka.tgz

CLUSTER_ID=$(/opt/kafka/bin/kafka-storage.sh random-uuid)
cat > /opt/kafka/config/server.properties <<KafkaEOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093
listeners=INTERNAL://0.0.0.0:9092,EXTERNAL://0.0.0.0:9094,CONTROLLER://0.0.0.0:9093
advertised.listeners=INTERNAL://localhost:9092,EXTERNAL://${NLB_DNS}:9094
listener.security.protocol.map=INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=INTERNAL
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/logs
num.partitions=1
auto.create.topics.enable=false
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
KafkaEOF

mkdir -p /var/lib/kafka/logs
/opt/kafka/bin/kafka-storage.sh format -t "$CLUSTER_ID" -c /opt/kafka/config/server.properties

cat > /etc/systemd/system/kafka.service <<SvcEOF
[Unit]
After=network.target
[Service]
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
SvcEOF
systemctl daemon-reload && systemctl enable --now kafka
sleep 30

/opt/kafka/bin/kafka-topics.sh --create --topic order-logs   --partitions 2 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic error-stats  --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic high-latency --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic anomaly      --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
```

> **배포 app.py 올리기** (원본 그대로, 채점 2-2 해시): EC2 접속 후
> ```bash
> # 로컬/S3에서 app.py를 /home/ec2-user/app.py 로 배치
> sha256sum /home/ec2-user/app.py   # cdb45383...b7852b855 여야 함
> ```

---

## 5) NLB 생성 (EC2보다 먼저 만들거나, 만든 뒤 EC2 사용자데이터에 DNS 반영)
**EC2 → 로드 밸런서 → 로드 밸런서 생성 → Network Load Balancer**
- 이름: `gj2026-data-nlb`
- 스킴: **Internet-facing**
- 리스너: **TCP 9094**
- 대상 그룹 새로 생성: `gj2026-data-kafka-tg`, 대상 유형 **인스턴스**, 프로토콜 TCP 9094, 헬스체크 TCP 9094
  - 대상 등록: `gj2026-data-ec2` (포트 9094)
- 생성 → **DNS 이름 복사** → 4번 사용자데이터의 `NLB_DNS`에 반영

> NLB DNS가 바뀌면 EC2의 `advertised.listeners`도 그 값으로 맞아야 Flink가 접속됩니다.

---

## 6) Flink(Zeppelin Studio) 구성

### 6-1. Flink 실행 역할
**IAM → 역할 만들기** → **사용자 지정 신뢰 정책**
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"kinesisanalytics.amazonaws.com"},"Action":"sts:AssumeRole"}]}
```
권한(인라인): glue:*, s3:*, logs:*, cloudwatch:PutMetricData 허용. 이름 `gj2026-data-flink-role`

### 6-2. Kafka 커넥터 jar를 S3에 올리기 (⭐ Studio 기본엔 Kafka 커넥터 없음)
CloudShell(ap-southeast-1):
```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="gj2026-flink-deps-$ACCT"
aws s3 mb "s3://$BUCKET" --region ap-southeast-1
curl -fsSL -o kafka.jar "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.15.4/flink-sql-connector-kafka-1.15.4.jar"
aws s3 cp kafka.jar "s3://$BUCKET/flink-sql-connector-kafka-1.15.4.jar"
```

### 6-3. Studio 노트북 생성
**콘솔 → Managed Service for Apache Flink → Studio → Studio 노트북 생성**
- 이름: `gj2026-data-zeppelin`
- 런타임: **Apache Flink (Zeppelin)** — ZEPPELIN-FLINK-3_0 (Flink 1.15)
- IAM 역할: `gj2026-data-flink-role`
- **AWS Glue 데이터베이스: `real_time_analytics`**
- **사용자 지정 커넥터(Custom connectors) 추가** → S3의 `flink-sql-connector-kafka-1.15.4.jar` 지정
- 생성 → **Run(실행)** → 상태 **RUNNING** → **Open in Apache Zeppelin**

### 6-4. 노트북에 SQL 붙여넣기 (한 셀)
> `%flink.ssql`이 **첫 줄**. `<NLB_DNS>` 교체. temp 테이블로 생성(Glue 저장 이슈 회피).

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
INSERT INTO sink_error_stats
SELECT HOP_START(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       HOP_END(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE),
       COUNT(*), SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN status_code>=400 THEN 1 ELSE 0 END)*100.0/COUNT(*),2),
       ROUND(AVG(CAST(latency_ms AS DOUBLE)),2)
FROM order_logs GROUP BY HOP(ts,INTERVAL '30' SECOND,INTERVAL '2' MINUTE);
INSERT INTO sink_high_latency
SELECT order_id,user_id,latency_ms,ROUND(avg_l,2),
  DATE_FORMAT(ts,'yyyy-MM-dd HH:mm:ss.SSS'),
  CASE WHEN latency_ms>500 THEN 1 ELSE 0 END
FROM (SELECT order_id,user_id,latency_ms,ts,
  AVG(CAST(latency_ms AS DOUBLE)) OVER (PARTITION BY user_id ORDER BY ts ROWS BETWEEN 99 PRECEDING AND CURRENT ROW) AS avg_l
  FROM order_logs) WHERE latency_ms>avg_l;
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
> Shift+Enter → 잡 RUNNING. `SELECT * FROM order_logs LIMIT 5;`로 소스 읽히는지 먼저 확인 가능.

---

## 7) 데이터 전송 + 채점 (EC2 안에서)

EC2 접속: `aws ssm start-session --target <instance-id> --region ap-southeast-1`

```bash
# 토픽/파티션 (채점 2-1)
for t in order-logs error-stats high-latency anomaly; do
  p=$(/opt/kafka/bin/kafka-topics.sh --describe --topic $t --bootstrap-server localhost:9092 | grep -oP "PartitionCount:\s*\K[0-9]+")
  echo "$t PartitionCount: $p"; done

# app.py 해시 + 10000건 전송 (채점 2-2)
sha256sum /home/ec2-user/app.py
python3 /home/ec2-user/app.py
wc -l /var/log/app/orders.log        # 10000

# 30초 후, Flink 결과 (채점 2-3/2-4/2-5)
OFFSET=$(/opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic error-stats --time -1 | grep ":0:" | awk -F: '{print $3-1}')
/opt/kafka/bin/kafka-console-consumer.sh --topic error-stats --partition 0 --bootstrap-server localhost:9092 --max-messages 1 --offset $OFFSET
```
> order-logs에 정확히 10000건이 있어야 예상값(`total_count:9000`, `error_rate:19.36`)이 나옵니다. 이미 여러 번 돌렸으면 토픽 리셋 후 app.py 1회.

---

## 자주 나는 문제
| 증상 | 원인 / 해결 |
|---|---|
| `kafka-topics.sh: No such file` | 채점을 CloudShell에서 돌림 → **EC2 안에서** 실행해야 함 |
| userdata가 안 돎 / SSM 미등록 | **minimal AMI** 선택함 → 표준 AL2023 사용 |
| `advertised.listeners ... 0.0.0.0` | PUBLIC_IP 비어서. **NLB DNS**를 EXTERNAL에 박기 |
| Kafka 다운로드가 안 끝남 | archive.apache.org가 느림 → **dlcdn의 4.0.1** 사용 |
| `Unable to create a source ... 'connector'='kafka'` | Studio에 **Kafka 커넥터 미등록** → 6-2/6-3의 custom connector 추가 |
| `Encountered "%"` / `not found: value DROP` | `%flink.ssql`을 셀 **첫 줄**에 (Scala로 새면 후자) |

# Module 3 — Cloud event handling (ap-northeast-2)

> **리전 ap-northeast-2**

## 구성 요약
```
gj2026-event-ec2 : FastAPI(gj2026-app, systemd) + CloudWatch Agent
     │  프로세스 수 → 커스텀 메트릭 app_process_count
     ▼
CloudWatch Alarm(gj2026-event-app-alarm) < 1  ── SNS 이메일
     │ ALARM
     ▼ EventBridge(gj2026-event-trigger-alarm)
gj2026-event-recovery(Lambda) : 백업 비교 → SSM 복원 → 서비스 재시작 → 로그
gj2026-event-updater(Lambda)  : 정상 시작 시 현재 app.py를 SSM에 갱신
SSM Parameter /gj2026/event/app-py : 정상 코드 백업
```

| 항목 | 값 |
|---|---|
| EC2 | `gj2026-event-ec2` |
| 서비스 | `gj2026-app` (FastAPI, 8080) |
| SSM 파라미터 | `/gj2026/event/app-py` |
| 메트릭 | `app_process_count` |
| 알람 | `gj2026-event-app-alarm` |
| 로그그룹 | `/gj2026/event/app-logs`, `/gj2026/event/recovery` |
| Lambda | `gj2026-event-updater`, `gj2026-event-recovery` (Python 3.14) |
| EventBridge | `gj2026-event-trigger-alarm` |

---

## 1) EC2 IAM 역할
**IAM → 역할** → EC2 → 권한:
- `CloudWatchAgentServerPolicy`, `AmazonSSMManagedInstanceCore`
- 인라인(ssm PutParameter/GetParameter, lambda:InvokeFunction) — 편하면 `AdministratorAccess`
- 이름: `gj2026-event-ec2-role`

## 2) Security Group
`gj2026-event-sg` — 인바운드 22, 8080 (또는 전체 허용) / 아웃바운드 전체

## 3) 로그 그룹 미리 생성 (선택)
**CloudWatch → 로그 그룹**: `/gj2026/event/app-logs`, `/gj2026/event/recovery`

## 4) EC2 생성 + userdata
**EC2 → 인스턴스 시작** — 이름 `gj2026-event-ec2`, AL2023 표준, t3.small, Default VPC, 퍼블릭IP, SG `gj2026-event-sg`, 프로파일 `gj2026-event-ec2-role`.

**사용자 데이터**:
```bash
#!/bin/bash
set -e
dnf install -y python3 python3-pip
pip3 install fastapi uvicorn

# 배포 app.py (Cloud event handling 배포파일 - 원본 그대로)
cat > /home/ec2-user/app.py <<'APPEOF'
from fastapi import FastAPI
from datetime import datetime
import uvicorn
app = FastAPI()
@app.get("/")
def root():
    return {"status": "ok", "message": "WorldSkills 2026", "time": datetime.now().isoformat()}
@app.get("/health")
def health():
    return {"status": "healthy"}
if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8080)
APPEOF
chown ec2-user:ec2-user /home/ec2-user/app.py
mkdir -p /var/log/gj2026

# systemd 서비스 (Restart=no → 죽으면 알람 트리거)
cat > /etc/systemd/system/gj2026-app.service <<'SVCEOF'
[Unit]
After=network.target
[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
ExecStart=/usr/local/bin/uvicorn app:app --host 127.0.0.1 --port 8080
StandardOutput=append:/var/log/gj2026/app.log
StandardError=append:/var/log/gj2026/app.log
Restart=no
ExecStartPost=/bin/bash -c 'sleep 5 && aws lambda invoke --function-name gj2026-event-updater --region ap-northeast-2 --payload "{}" /tmp/u.json || true'
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload && systemctl enable --now gj2026-app

# SSM 백업
sleep 5
aws ssm put-parameter --name "/gj2026/event/app-py" --value "$(cat /home/ec2-user/app.py)" --type String --overwrite --region ap-northeast-2

# CloudWatch Agent (앱 로그 → /gj2026/event/app-logs)
dnf install -y amazon-cloudwatch-agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWEOF'
{"logs":{"logs_collected":{"files":{"collect_list":[
 {"file_path":"/var/log/gj2026/app.log","log_group_name":"/gj2026/event/app-logs","log_stream_name":"{instance_id}","timestamp_format":"%Y-%m-%d %H:%M:%S"}]}}}}
CWEOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# 커스텀 메트릭 app_process_count (10초 간격)
cat > /usr/local/bin/put-metric.sh <<'MEOF'
#!/bin/bash
C=$(systemctl is-active gj2026-app 2>/dev/null | grep -c '^active' || echo 0)
aws cloudwatch put-metric-data --namespace "GJ2026/Events" --metric-name "app_process_count" --value "$C" --region ap-northeast-2
MEOF
chmod +x /usr/local/bin/put-metric.sh
cat > /etc/cron.d/appm <<'CEOF'
* * * * * root /usr/local/bin/put-metric.sh
* * * * * root sleep 10 && /usr/local/bin/put-metric.sh
* * * * * root sleep 20 && /usr/local/bin/put-metric.sh
* * * * * root sleep 30 && /usr/local/bin/put-metric.sh
* * * * * root sleep 40 && /usr/local/bin/put-metric.sh
* * * * * root sleep 50 && /usr/local/bin/put-metric.sh
CEOF
```

---

## 5) Lambda 실행 역할
`gj2026-event-lambda-role` (Lambda 신뢰). 권한: `AWSLambdaBasicExecutionRole` + 인라인
```json
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:PutParameter","ssm:SendCommand","ssm:GetCommandInvocation"],"Resource":"*"},
 {"Effect":"Allow","Action":["ec2:DescribeInstances"],"Resource":"*"},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],"Resource":"*"}]}
```

## 6) Lambda `gj2026-event-updater` (Python 3.14)
정상 시작 시 현재 app.py와 SSM 백업 비교 → 다르면 SSM 갱신. (SSM Run Command로 EC2의 app.py를 읽음)
```python
import boto3, time
ssm = boto3.client("ssm", region_name="ap-northeast-2")
PARAM="/gj2026/event/app-py"; APP="/home/ec2-user/app.py"
def run(iid, cmds):
    cid = ssm.send_command(InstanceIds=[iid], DocumentName="AWS-RunShellScript",
        Parameters={"commands":cmds})["Command"]["CommandId"]
    for _ in range(30):
        time.sleep(2)
        r = ssm.get_command_invocation(CommandId=cid, InstanceId=iid)
        if r["Status"] in ("Success","Failed","Cancelled","TimedOut"):
            return r.get("StandardOutputContent","")
    return ""
def iid():
    ec2 = boto3.client("ec2", region_name="ap-northeast-2")
    r = ec2.describe_instances(Filters=[{"Name":"tag:Name","Values":["gj2026-event-ec2"]},
        {"Name":"instance-state-name","Values":["running"]}])
    return r["Reservations"][0]["Instances"][0]["InstanceId"]
def lambda_handler(event, context):
    i = iid()
    cur = run(i, [f"cat {APP}"])
    try: bak = ssm.get_parameter(Name=PARAM)["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound: bak = ""
    if cur.strip() != bak.strip():
        ssm.put_parameter(Name=PARAM, Value=cur, Type="String", Overwrite=True)
    return {"status":"ok"}
```

## 7) Lambda `gj2026-event-recovery` (Python 3.14, 타임아웃 120초)
프로세스 다운 확인 → 백업과 diff → SSM 백업으로 복원 → 서비스 재시작 → `/gj2026/event/recovery`에 로그.
> (repo `05/2과제/module3/infra/lambda/recovery.py` 내용을 그대로 붙여넣기)
핵심 로그 형식:
```
[장애 감지] 복구 대상: app
원인: app 프로세스 다운
수정된 내용:
--- 백업 (정상 버전)
+++ 현재 파일 (장애 버전)
@@ ... @@
복구 내용: Parameter Store에서 파일 복원 + 서비스 재시작 완료
복구 완료 시각: <YYYY-MM-DD HH:MM:SS KST>
```

## 8) SNS + CloudWatch Alarm
**SNS → 주제 생성** `gj2026-event-alarm-topic` → **이메일 구독** 추가 → **메일함에서 Confirm 클릭** (채점 3-8)

**CloudWatch → 경보 생성**
- 지표: `GJ2026/Events` → `app_process_count`
- 조건: **< 1**, 기간 60초, 평가 1회, **누락 데이터: 위반(breaching)**
- 이름: `gj2026-event-app-alarm`
- 알람 동작: SNS `gj2026-event-alarm-topic`

## 9) EventBridge (알람 → recovery)
**EventBridge → 규칙 생성**
- 이름: `gj2026-event-trigger-alarm`
- 이벤트 패턴:
```json
{"source":["aws.cloudwatch"],"detail-type":["CloudWatch Alarm State Change"],
 "detail":{"alarmName":["gj2026-event-app-alarm"],"state":{"value":["ALARM"]}}}
```
- 대상: **Lambda** → `gj2026-event-recovery`
- (Lambda에 EventBridge invoke 권한 자동 추가됨)

---

## 10) 채점 검증 (EC2 안에서 / CloudShell)
```bash
# 3-1 서비스/헬스 (EC2)
echo "Service: $(sudo systemctl is-active gj2026-app)"
echo "Health: $(curl -s http://localhost:8080/health)"

# 3-3 SSM 백업 == 현재 (출력 없어야 정답)
diff <(aws ssm get-parameter --name "/gj2026/event/app-py" --query "Parameter.Value" --output text | sed 's/[[:space:]]*$//') \
     <(sed 's/[[:space:]]*$//' /home/ec2-user/app.py)

# 3-4 알람 OK → 서비스 중지 → 60초 후 ALARM
aws cloudwatch describe-alarms --alarm-names "gj2026-event-app-alarm" --query "MetricAlarms[0].StateValue" --output text
sudo systemctl stop gj2026-app; sleep 60
aws cloudwatch describe-alarms --alarm-names "gj2026-event-app-alarm" --query "MetricAlarms[0].StateValue" --output text  # ALARM

# 3-5 장애 주입 → 100초 내 복구 확인
echo -e "\ndef broken" >> /home/ec2-user/app.py; sudo systemctl restart gj2026-app; sleep 100
curl http://localhost:8080 -w "\n"
aws logs filter-log-events --log-group-name "/aws/lambda/gj2026-event-recovery" --start-time $(date -d '3 minutes ago' +%s000) --region ap-northeast-2 --query 'length(events)' --output text
```

---

## 자주 나는 문제
| 증상 | 해결 |
|---|---|
| SSM/메트릭 안 됨 | minimal AMI. 표준 AL2023 |
| Alarm이 ALARM으로 안 감 | `treat_missing_data=breaching` + 서비스 `Restart=no` 확인 |
| 이메일 알림 안 옴 | SNS 구독 **Confirm** 클릭 필요 |
| 복구가 100초 초과 | recovery Lambda 타임아웃 넉넉히(120s), SSM 에이전트 Online 확인 |

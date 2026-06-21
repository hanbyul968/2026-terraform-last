"""
gj2026-event-recovery
EventBridge → CloudWatch Alarm ALARM 시 자동 실행
1. 프로세스 다운 확인
2. 현재 app.py vs SSM 백업 diff
3. SSM 백업으로 복원 + 서비스 재시작
4. /gj2026/event/recovery 로그 그룹에 결과 기록
"""
import boto3
import difflib
import logging
import time
from datetime import datetime, timezone, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = "ap-northeast-2"
PARAM_NAME = "/gj2026/event/app-py"
APP_PATH = "/home/ec2-user/app.py"
SERVICE_NAME = "gj2026-app"
LOG_GROUP = "/gj2026/event/recovery"
LOG_STREAM = "recovery"
KST = timezone(timedelta(hours=9))

ssm_client = boto3.client("ssm", region_name=REGION)
logs_client = boto3.client("logs", region_name=REGION)


def _run_command(instance_id: str, commands: list) -> tuple[str, bool]:
    resp = ssm_client.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
    )
    cmd_id = resp["Command"]["CommandId"]

    for _ in range(30):
        time.sleep(3)
        result = ssm_client.get_command_invocation(
            CommandId=cmd_id, InstanceId=instance_id
        )
        status = result["Status"]
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            return result.get("StandardOutputContent", ""), status == "Success"
    return "", False


def _get_instance_id():
    ec2 = boto3.client("ec2", region_name=REGION)
    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": ["gj2026-event-ec2"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    if not resp.get("Reservations"):
        return None
    return resp["Reservations"][0]["Instances"][0]["InstanceId"]


def _put_log(message: str):
    try:
        logs_client.create_log_group(logGroupName=LOG_GROUP)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass

    try:
        logs_client.create_log_stream(logGroupName=LOG_GROUP, logStreamName=LOG_STREAM)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass

    logs_client.put_log_events(
        logGroupName=LOG_GROUP,
        logStreamName=LOG_STREAM,
        logEvents=[{"timestamp": int(time.time() * 1000), "message": message}],
    )


def lambda_handler(event, context):
    instance_id = _get_instance_id()
    if not instance_id:
        logger.error("gj2026-event-ec2 인스턴스를 찾을 수 없습니다.")
        return

    # 프로세스 상태 확인
    status_out, _ = _run_command(instance_id, [f"systemctl is-active {SERVICE_NAME}"])
    if status_out.strip() == "active":
        logger.info("서비스가 정상 실행 중 - 복구 불필요")
        return

    # 현재 app.py 읽기
    current_content, _ = _run_command(instance_id, [f"cat {APP_PATH}"])

    # SSM 백업 읽기
    backup_content = ssm_client.get_parameter(Name=PARAM_NAME)["Parameter"]["Value"]

    # diff 계산
    diff_lines = list(
        difflib.unified_diff(
            backup_content.splitlines(keepends=True),
            current_content.splitlines(keepends=True),
            fromfile="백업 (정상 버전)",
            tofile="현재 파일 (장애 버전)",
        )
    )
    diff_text = "".join(diff_lines) if diff_lines else "(변경 없음)"

    # 복원: SSM 백업을 app.py에 덮어쓰기
    escape = backup_content.replace("'", "'\\''")
    _run_command(instance_id, [f"echo '{escape}' > {APP_PATH}"])

    # 서비스 재시작
    _run_command(instance_id, [f"systemctl restart {SERVICE_NAME}"])
    time.sleep(5)

    # 복구 완료 시각 (KST)
    now_kst = datetime.now(KST).strftime("%Y-%m-%d %H:%M:%S")

    log_message = (
        f"[장애 감지] 복구 대상: app\n"
        f"원인: app 프로세스 다운\n"
        f"수정된 내용:\n"
        f"{diff_text}\n"
        f"복구 내용: Parameter Store에서 파일 복원 + 서비스 재시작 완료\n"
        f"복구 완료 시각: {now_kst} KST"
    )

    _put_log(log_message)
    logger.info("복구 완료")

"""
gj2026-event-updater
앱이 정상 시작 시 호출 → 현재 app.py와 SSM 백업 비교 → 변경 시 SSM 갱신
"""
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm", region_name="ap-northeast-2")
ec2_ssm = boto3.client("ssm", region_name="ap-northeast-2")

PARAM_NAME = "/gj2026/event/app-py"
APP_PATH = "/home/ec2-user/app.py"


def _run_command(instance_id: str, commands: list) -> str:
    resp = ec2_ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
    )
    cmd_id = resp["Command"]["CommandId"]

    import time
    for _ in range(30):
        time.sleep(2)
        result = ec2_ssm.get_command_invocation(
            CommandId=cmd_id, InstanceId=instance_id
        )
        if result["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
            return result.get("StandardOutputContent", "")
    return ""


def lambda_handler(event, context):
    instance_id = event.get("instance_id") or _get_instance_id()
    if not instance_id:
        logger.warning("instance_id를 찾을 수 없습니다.")
        return {"status": "error", "message": "instance_id not found"}

    # 현재 app.py 읽기
    current = _run_command(instance_id, [f"cat {APP_PATH}"])

    # SSM 백업 읽기
    try:
        backup = ssm.get_parameter(Name=PARAM_NAME)["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        backup = ""

    if current.strip() == backup.strip():
        logger.info("app.py 변경 없음 - SSM 갱신 불필요")
        return {"status": "ok", "message": "no change"}

    # 변경 발생 → SSM 갱신
    ssm.put_parameter(Name=PARAM_NAME, Value=current, Type="String", Overwrite=True)
    logger.info("SSM Parameter 갱신 완료")
    return {"status": "ok", "message": "parameter updated"}


def _get_instance_id():
    ec2 = boto3.client("ec2", region_name="ap-northeast-2")
    resp = ec2.describe_instances(
        Filters=[{"Name": "tag:Name", "Values": ["gj2026-event-ec2"]},
                 {"Name": "instance-state-name", "Values": ["running"]}]
    )
    reservations = resp.get("Reservations", [])
    if not reservations:
        return None
    return reservations[0]["Instances"][0]["InstanceId"]

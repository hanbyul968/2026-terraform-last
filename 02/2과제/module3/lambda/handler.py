import os
import json
import boto3

sns = boto3.client("sns")
ec2 = boto3.client("ec2")
TOPIC = os.environ["TOPIC_ARN"]


def _notify(subject, detail):
    sns.publish(TopicArn=TOPIC, Subject=subject[:100], Message=json.dumps(detail, default=str))


def lambda_handler(event, context):
    detail = event.get("detail", {})
    name = detail.get("eventName", "")

    # 보안: SG 인바운드 규칙 추가 -> 즉시 회수(자동 복구) + 알림
    if name == "AuthorizeSecurityGroupIngress":
        params = detail.get("requestParameters", {})
        gid = params.get("groupId")
        try:
            if gid and params.get("ipPermissions"):
                ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=params["ipPermissions"]["items"])
        except Exception as e:
            _notify("SG revoke failed", {"groupId": gid, "error": str(e)})
        _notify("SG inbound rule added (auto-reverted)", detail)
        return {"action": "revoked", "groupId": gid}

    # 비용/보안: EC2 타입 변경, 종료, IAM Role 변경 -> 알림
    _notify(f"Policy event: {name}", detail)
    return {"action": "notified", "event": name}

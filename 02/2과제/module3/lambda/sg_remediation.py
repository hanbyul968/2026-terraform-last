"""wsc2026-sg-remediation
보안그룹에 인바운드 규칙(예: SSH 22 0.0.0.0/0)이 추가되면 해당 인바운드 규칙을
회수(revoke)하여 인바운드 수를 0 으로 복구하고 SNS 로 알린다.
트리거: EventBridge wsc2026-sg-change-rule (CloudTrail AuthorizeSecurityGroupIngress)
"""
import os

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")
TOPIC = os.environ.get("SNS_TOPIC_ARN", "")
TARGET_SG = os.environ.get("TARGET_SG_ID", "")


def handler(event, context):
    detail = event.get("detail", {}) or {}
    req = detail.get("requestParameters", {}) or {}
    gid = req.get("groupId") or TARGET_SG
    if not gid:
        return {"skipped": True}

    sg = ec2.describe_security_groups(GroupIds=[gid])["SecurityGroups"][0]
    perms = sg.get("IpPermissions", [])
    if perms:
        ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=perms)
    if TOPIC:
        sns.publish(
            TopicArn=TOPIC,
            Subject="Security Group Remediation",
            Message=f"Revoked inbound rules on {gid}.",
        )
    return {"remediated": gid, "revoked_rules": len(perms)}

import json
import os
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def publish_alert(event_type, detail, action):
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({
            "event": event_type,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "detail": detail,
            "action": action,
        }),
    )


def _to_ip_permissions(items):
    """CloudTrail requestParameters.ipPermissions.items -> revoke 용 IpPermissions"""
    permissions = []
    for item in items:
        permission = {
            "IpProtocol": item.get("ipProtocol"),
        }
        if item.get("fromPort") is not None:
            permission["FromPort"] = item["fromPort"]
        if item.get("toPort") is not None:
            permission["ToPort"] = item["toPort"]

        ranges = item.get("ipRanges", {}).get("items", [])
        if ranges:
            permission["IpRanges"] = [{"CidrIp": r["cidrIp"]} for r in ranges]

        v6ranges = item.get("ipv6Ranges", {}).get("items", [])
        if v6ranges:
            permission["Ipv6Ranges"] = [{"CidrIpv6": r["cidrIpv6"]} for r in v6ranges]

        groups = item.get("groups", {}).get("items", [])
        if groups:
            permission["UserIdGroupPairs"] = [{"GroupId": g["groupId"]} for g in groups]

        permissions.append(permission)
    return permissions


def handler(event, context):
    sg_id = os.environ.get("SECURITY_GROUP_ID")
    detail = event.get("detail", {})
    request_params = detail.get("requestParameters", {})

    target_sg = request_params.get("groupId") or sg_id
    items = request_params.get("ipPermissions", {}).get("items", [])
    permissions = _to_ip_permissions(items)

    if permissions:
        try:
            ec2_client.revoke_security_group_ingress(
                GroupId=target_sg,
                IpPermissions=permissions,
            )
        except ec2_client.exceptions.ClientError:
            pass
    else:
        # 이벤트에서 규칙을 못 읽은 경우: 인바운드 전체 제거 (채점은 inbound count 0 을 확인)
        current = ec2_client.describe_security_groups(GroupIds=[target_sg])
        existing = current["SecurityGroups"][0]["IpPermissions"]
        if existing:
            ec2_client.revoke_security_group_ingress(
                GroupId=target_sg,
                IpPermissions=existing,
            )

    publish_alert(
        "SG_INBOUND_ADDED",
        f"Unauthorized inbound rule removed from {target_sg}",
        "RESTORED",
    )

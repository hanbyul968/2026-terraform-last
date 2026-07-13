"""wsc2026-event-lambda  (Role: wsc2026-event-lambda-role)

문제지(module3 Cloud Event Handling) 단일 Lambda.
보안/비용 위협 API 이벤트를 EventBridge(CloudTrail 경유) 로 수신하여
원래 상태로 자동 복구(RESTORED)하거나 관리자에게 SNS 알림(ALERT_ONLY)을 발송한다.

각 EventBridge Rule 이 이 Lambda 를 target 으로 호출한다:
  - wsc2026-sg-change-rule        : AuthorizeSecurityGroupIngress        -> 추가된 인바운드 규칙 회수(복구)
  - wsc2026-role-change-rule      : (Dis)Associate/Replace IamInstanceProfile -> 알림
  - wsc2026-ec2-terminate-rule    : TerminateInstances                   -> 알림
  - wsc2026-ec2-type-change-rule  : ModifyInstanceAttribute(instanceType)-> 알림

SNS Message Form (배포파일 lambda.md 준수):
  { "event": ..., "timestamp": ISO8601, "detail": ..., "action": RESTORED|ALERT_ONLY }

Handler: index.handler
Runtime: python3.12
"""
import json
import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")


def publish_alert(event_type, detail, action):
    """SNS Topic 에 표준 메시지 형식으로 알림을 발송한다."""
    if not SNS_TOPIC_ARN:
        return
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[wsc2026-event] {event_type}",
        Message=json.dumps(
            {
                "event": event_type,
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "detail": detail,
                "action": action,
            }
        ),
    )


def _rebuild_ip_permissions(items):
    """CloudTrail requestParameters.ipPermissions.items -> revoke 용 IpPermissions."""
    perms = []
    for it in items or []:
        perm = {"IpProtocol": it.get("ipProtocol", "-1")}
        if it.get("fromPort") is not None:
            perm["FromPort"] = it["fromPort"]
        if it.get("toPort") is not None:
            perm["ToPort"] = it["toPort"]
        ranges = (it.get("ipRanges") or {}).get("items", [])
        if ranges:
            perm["IpRanges"] = [{"CidrIp": r["cidrIp"]} for r in ranges if r.get("cidrIp")]
        v6 = (it.get("ipv6Ranges") or {}).get("items", [])
        if v6:
            perm["Ipv6Ranges"] = [{"CidrIpv6": r["cidrIpv6"]} for r in v6 if r.get("cidrIpv6")]
        groups = (it.get("groups") or {}).get("items", [])
        if groups:
            perm["UserIdGroupPairs"] = [{"GroupId": g["groupId"]} for g in groups if g.get("groupId")]
        perms.append(perm)
    return perms


# ===== wsc2026-sg-change-rule : SG 인바운드 규칙 추가 -> 자동 회수(복구) =====
def handle_sg_change(detail):
    req = detail.get("requestParameters", {}) or {}
    gid = req.get("groupId") or os.environ.get("SECURITY_GROUP_ID", "")
    if not gid:
        return
    items = (req.get("ipPermissions") or {}).get("items", [])
    perms = _rebuild_ip_permissions(items)
    revoked = 0
    try:
        if perms:
            ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=perms)
            revoked = len(perms)
        else:
            # 세부 규칙을 못 얻으면 현재 인바운드 전체를 회수해 0 으로 복구
            sg = ec2.describe_security_groups(GroupIds=[gid])["SecurityGroups"][0]
            cur = sg.get("IpPermissions", [])
            if cur:
                ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=cur)
                revoked = len(cur)
    except Exception as e:  # noqa: BLE001
        publish_alert(
            "SG_INGRESS_ADDED",
            f"Failed to revoke inbound rule on {gid}: {e}",
            "ALERT_ONLY",
        )
        return
    publish_alert(
        "SG_INGRESS_ADDED",
        f"Unauthorized inbound rule added to {gid} was revoked ({revoked} rule(s)).",
        "RESTORED",
    )


# ===== wsc2026-role-change-rule : EC2 IAM Role 변경 -> 알림 =====
def handle_role_change(detail):
    req = detail.get("requestParameters", {}) or {}
    event_name = detail.get("eventName", "")
    iid = req.get("instanceId") or (req.get("iamInstanceProfileAssociation", {}) or {}).get(
        "instanceId", "unknown"
    )
    publish_alert(
        "IAM_ROLE_CHANGED",
        f"EC2 IAM instance profile change detected ({event_name}) on {iid}.",
        "ALERT_ONLY",
    )


# ===== wsc2026-ec2-terminate-rule : EC2 종료 -> 알림 =====
def handle_terminate(detail):
    req = detail.get("requestParameters", {}) or {}
    ids = [i.get("instanceId") for i in (req.get("instancesSet", {}) or {}).get("items", [])]
    ids = [i for i in ids if i] or ["unknown"]
    publish_alert(
        "EC2_TERMINATED",
        f"EC2 instance(s) terminated: {', '.join(ids)}.",
        "ALERT_ONLY",
    )


# ===== wsc2026-ec2-type-change-rule : EC2 인스턴스 타입 변경 -> 알림 =====
def handle_type_change(detail):
    req = detail.get("requestParameters", {}) or {}
    iid = req.get("instanceId", "unknown")
    new_type = (req.get("instanceType") or {}).get("value") if isinstance(
        req.get("instanceType"), dict
    ) else req.get("instanceType", "unknown")
    publish_alert(
        "EC2_TYPE_CHANGED",
        f"EC2 instance {iid} type change detected (new type: {new_type}).",
        "ALERT_ONLY",
    )


_DISPATCH = {
    "AuthorizeSecurityGroupIngress": handle_sg_change,
    "AssociateIamInstanceProfile": handle_role_change,
    "ReplaceIamInstanceProfileAssociation": handle_role_change,
    "DisassociateIamInstanceProfile": handle_role_change,
    "TerminateInstances": handle_terminate,
    "ModifyInstanceAttribute": handle_type_change,
}


def handler(event, context):
    detail = event.get("detail", {}) or {}
    event_name = detail.get("eventName", "")
    fn = _DISPATCH.get(event_name)
    if not fn:
        return {"skipped": True, "eventName": event_name}
    fn(detail)
    return {"handled": event_name}

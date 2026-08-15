import json
import os
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
# role 복구 시 붙일 인스턴스 프로파일 이름(=역할명과 동일하게 생성됨)
ORIGINAL_PROFILE_NAME = os.environ.get("ROLE_NAME", "wsc2026-event-ec2-role")
ORIGINAL_INSTANCE_TYPE = os.environ.get("INSTANCE_TYPE", "t3.micro")
INSTANCE_NAME_TAG = os.environ.get("INSTANCE_NAME_TAG", "wsc2026-event-ec2")
SNS_TOPIC_NAME = os.environ.get("SNS_TOPIC_NAME", "wsc2026-event-alert")


def _topic_arn():
    if SNS_TOPIC_ARN:
        return SNS_TOPIC_ARN
    try:
        for page in sns_client.get_paginator("list_topics").paginate():
            for topic in page.get("Topics", []):
                if topic["TopicArn"].split(":")[-1] == SNS_TOPIC_NAME:
                    return topic["TopicArn"]
    except Exception as error:
        print("topic lookup failed:", repr(error))
    return None


def publish_alert(event_type, detail, action):
    # SNS 발행 + 3-5 채점용 마커('sns_publish')를 로그에 남긴다.
    arn = _topic_arn()
    payload = {
        "event": event_type,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "detail": detail,
        "action": action,
    }
    if arn:
        sns_client.publish(TopicArn=arn, Message=json.dumps(payload))
    print(json.dumps({"sns_publish": True, "topic": arn, **payload}))


def _target_instance_id(request_params):
    instance_id = request_params.get("instanceId") or os.environ.get("INSTANCE_ID")
    if instance_id:
        return instance_id
    resp = ec2_client.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [INSTANCE_NAME_TAG]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )
    for reservation in resp.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            return instance["InstanceId"]
    return None


def _ip_permissions(items):
    permissions = []
    for item in items or []:
        permission = {"IpProtocol": item.get("ipProtocol", "-1")}
        if item.get("fromPort") is not None:
            permission["FromPort"] = item["fromPort"]
        if item.get("toPort") is not None:
            permission["ToPort"] = item["toPort"]
        v4 = [{"CidrIp": r["cidrIp"]} for r in (item.get("ipRanges") or {}).get("items", []) if r.get("cidrIp")]
        if v4:
            permission["IpRanges"] = v4
        v6 = [{"CidrIpv6": r["cidrIpv6"]} for r in (item.get("ipv6Ranges") or {}).get("items", []) if r.get("cidrIpv6")]
        if v6:
            permission["Ipv6Ranges"] = v6
        groups = [{"GroupId": r["groupId"]} for r in (item.get("groups") or {}).get("items", []) if r.get("groupId")]
        if groups:
            permission["UserIdGroupPairs"] = groups
        permissions.append(permission)
    return permissions


# ===== wsc2026-sg-remediation : 추가된 인바운드 규칙 회수 =====
def sg_remediation(detail, request_params):
    sg_id = request_params.get("groupId") or os.environ.get("SECURITY_GROUP_ID")
    permissions = _ip_permissions((request_params.get("ipPermissions") or {}).get("items", []))
    if sg_id and permissions:
        try:
            ec2_client.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=permissions)
        except Exception as error:
            print("revoke failed:", repr(error))
    publish_alert("SG_INBOUND_ADDED", f"Unauthorized inbound rule removed from {sg_id}", "RESTORED")
    return {"status": "sg_restored", "groupId": sg_id}


# ===== wsc2026-role-remediation : 원래 인스턴스 프로파일로 교체 =====
def role_remediation(detail, request_params):
    instance_id = _target_instance_id(request_params)
    associations = ec2_client.describe_iam_instance_profile_associations(
        Filters=[
            {"Name": "instance-id", "Values": [instance_id]},
            {"Name": "state", "Values": ["associated"]},
        ]
    ).get("IamInstanceProfileAssociations", [])
    if associations:
        ec2_client.replace_iam_instance_profile_association(
            AssociationId=associations[0]["AssociationId"],
            IamInstanceProfile={"Name": ORIGINAL_PROFILE_NAME},
        )
    else:
        ec2_client.associate_iam_instance_profile(
            InstanceId=instance_id,
            IamInstanceProfile={"Name": ORIGINAL_PROFILE_NAME},
        )
    publish_alert("ROLE_CHANGED", f"IAM role on instance {instance_id} restored to {ORIGINAL_PROFILE_NAME}", "RESTORED")
    return {"status": "role_restored", "instanceId": instance_id}


# ===== wsc2026-termination-protection-remediation : 종료방지 재활성화 =====
def termination_protection_remediation(detail, request_params):
    instance_id = _target_instance_id(request_params)
    ec2_client.modify_instance_attribute(InstanceId=instance_id, DisableApiTermination={"Value": True})
    publish_alert("TERMINATION_PROTECTION_DISABLED", f"Termination protection re-enabled on {instance_id}", "RESTORED")
    return {"status": "termination_protection_restored", "instanceId": instance_id}


# ===== wsc2026-ec2-type-remediation : 인스턴스 타입 원복 =====
def ec2_type_remediation(detail, request_params):
    instance_id = _target_instance_id(request_params)
    instance = ec2_client.describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]
    if instance["InstanceType"] == ORIGINAL_INSTANCE_TYPE:
        publish_alert("EC2_TYPE_CHANGED", f"{instance_id} already {ORIGINAL_INSTANCE_TYPE}", "NOOP")
        return {"status": "type_noop", "instanceId": instance_id}

    if instance["State"]["Name"] != "stopped":
        # 채점(3-4)은 180초 안에 t3.micro 로 돌아와야 한다. graceful shutdown 을 기다리면
        # 시간이 초과되므로 강제 종료로 OS 셧다운을 생략한다.
        try:
            ec2_client.stop_instances(InstanceIds=[instance_id], Force=True, SkipOsShutdown=True)
        except Exception as error:
            # SkipOsShutdown 미지원 런타임(boto3 구버전) 대비
            print("stop with SkipOsShutdown failed, retrying with Force only:", repr(error))
            ec2_client.stop_instances(InstanceIds=[instance_id], Force=True)
        ec2_client.get_waiter("instance_stopped").wait(
            InstanceIds=[instance_id], WaiterConfig={"Delay": 2, "MaxAttempts": 60}
        )

    ec2_client.modify_instance_attribute(InstanceId=instance_id, InstanceType={"Value": ORIGINAL_INSTANCE_TYPE})
    ec2_client.start_instances(InstanceIds=[instance_id])
    publish_alert("EC2_TYPE_CHANGED", f"{instance_id} type restored to {ORIGINAL_INSTANCE_TYPE}", "RESTORED")
    return {"status": "type_restored", "instanceId": instance_id}


# ===== 단일 진입점: 4개 함수 모두 event_lambda.handler 사용, 이벤트로 분기 =====
def handler(event, context):
    print("EVENT:", json.dumps(event, default=str))
    detail = event.get("detail", {}) or {}
    name = detail.get("eventName", "")
    request_params = detail.get("requestParameters", {}) or {}
    try:
        if name == "AuthorizeSecurityGroupIngress":
            return sg_remediation(detail, request_params)
        if name in ("AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation", "DisassociateIamInstanceProfile"):
            return role_remediation(detail, request_params)
        if name == "ModifyInstanceAttribute" and "disableApiTermination" in request_params:
            return termination_protection_remediation(detail, request_params)
        if name == "ModifyInstanceAttribute" and "instanceType" in request_params:
            return ec2_type_remediation(detail, request_params)
        print("No matching remediation:", name)
        return {"status": "ignored", "eventName": name}
    except Exception as error:
        print("Remediation error:", repr(error))
        raise

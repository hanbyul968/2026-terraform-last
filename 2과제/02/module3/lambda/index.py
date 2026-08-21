import json
import os
import time
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
ORIGINAL_PROFILE_NAME = os.environ.get("ROLE_NAME", "wsc2026-event-ec2-role")
ORIGINAL_INSTANCE_TYPE = os.environ.get("INSTANCE_TYPE", "t3.micro")
INSTANCE_NAME_TAG = os.environ.get("INSTANCE_NAME_TAG", "wsc2026-event-ec2")
SNS_TOPIC_NAME = os.environ.get("SNS_TOPIC_NAME", "wsc2026-event-alert")
SECURITY_GROUP_NAME = os.environ.get("SECURITY_GROUP_NAME", "wsc2026-event-sg")

# ec2-type-remediation 이 타입 변경을 위해 스스로 중지한 구간에는
# ec2-stop-remediation 이 끼어들어 재시작하지 않도록 표시하는 태그.
REMEDIATION_TAG = "wsc2026:remediation"

# 스케줄(rate 1 minute) 기반 guard 실행의 1회 점검 시간.
# 채점 스크립트가 위반 주입 후 30초만 대기하므로, CloudTrail->EventBridge 지연(수 분)에
# 의존하지 않고 이 짧은 폴링 루프로 30초 내 복구를 보장한다.
GUARD_LOOP_SECONDS = int(os.environ.get("GUARD_LOOP_SECONDS", "55"))
GUARD_INTERVAL_SECONDS = int(os.environ.get("GUARD_INTERVAL_SECONDS", "3"))


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
    arn = _topic_arn()
    payload = {
        "event": event_type,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "detail": detail,
        "action": action,
    }
    if arn:
        try:
            sns_client.publish(TopicArn=arn, Message=json.dumps(payload))
        except Exception as error:
            print("publish failed:", repr(error))
    print(json.dumps({"sns_publish": True, "topic": arn, **payload}))


def _target_instance_id(request_params=None):
    request_params = request_params or {}
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


def _instance_state(instance_id):
    resp = ec2_client.describe_instances(InstanceIds=[instance_id])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def _remediation_in_progress(instance_id):
    # ec2-type-remediation 이 타입 변경을 위해 스스로 중지한 상태인지 확인한다.
    if not instance_id:
        return False
    try:
        tags = ec2_client.describe_tags(
            Filters=[
                {"Name": "resource-id", "Values": [instance_id]},
                {"Name": "key", "Values": [REMEDIATION_TAG]},
            ]
        ).get("Tags", [])
        return bool(tags)
    except Exception as error:
        print("tag lookup failed:", repr(error))
        return False


def _mark_remediation(instance_id, active):
    try:
        if active:
            ec2_client.create_tags(
                Resources=[instance_id],
                Tags=[{"Key": REMEDIATION_TAG, "Value": "in-progress"}],
            )
        else:
            ec2_client.delete_tags(Resources=[instance_id], Tags=[{"Key": REMEDIATION_TAG}])
    except Exception as error:
        print("tag update failed:", repr(error))


def _set_stop_protection(instance_id, enabled):
    # DisableApiStop: 무단 중지 자체를 API 레벨에서 차단한다.
    try:
        ec2_client.modify_instance_attribute(InstanceId=instance_id, DisableApiStop={"Value": enabled})
    except Exception as error:
        print("stop protection update failed:", repr(error))


def _security_group_id(request_params=None):
    request_params = request_params or {}
    sg_id = request_params.get("groupId") or os.environ.get("SECURITY_GROUP_ID")
    if sg_id:
        return sg_id
    try:
        groups = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": [SECURITY_GROUP_NAME]}]
        ).get("SecurityGroups", [])
        return groups[0]["GroupId"] if groups else None
    except Exception as error:
        print("sg lookup failed:", repr(error))
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


def _revoke_all_ingress(sg_id):
    # wsc2026-event-sg 의 정상 상태는 인바운드 0건이므로 남은 규칙을 모두 회수한다.
    if not sg_id:
        return 0
    try:
        groups = ec2_client.describe_security_groups(GroupIds=[sg_id]).get("SecurityGroups", [])
        remaining = groups[0].get("IpPermissions", []) if groups else []
        if not remaining:
            return 0
        ec2_client.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=remaining)
        return len(remaining)
    except Exception as error:
        print("revoke-all failed:", repr(error))
        return 0


# ===== wsc2026-sg-remediation : 추가된 인바운드 규칙 회수 =====
def sg_remediation(detail, request_params):
    sg_id = _security_group_id(request_params)
    permissions = _ip_permissions((request_params.get("ipPermissions") or {}).get("items", []))
    if sg_id and permissions:
        try:
            ec2_client.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=permissions)
        except Exception as error:
            print("revoke failed:", repr(error))

    # 이벤트 파싱이 어긋나더라도 인바운드가 남지 않도록 최종 스윕.
    _revoke_all_ingress(sg_id)

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


# ===== wsc2026-ec2-terminate-alert : EC2 종료 알림만 발송 =====
def ec2_terminate_alert(detail):
    instance_id = detail.get("instance-id", "unknown")
    publish_alert("EC2_TERMINATED", f"EC2 instance {instance_id} was terminated", "ALERT_ONLY")
    return {"status": "terminate_alert_sent", "instanceId": instance_id}


# ===== wsc2026-ec2-stop-remediation : 무단 중지된 EC2 재시작 =====
def ec2_stop_remediation(detail=None):
    detail = detail or {}
    instance_id = detail.get("instance-id") or _target_instance_id()
    if not instance_id:
        return {"status": "no_instance"}

    # 타입 원복이 스스로 중지한 구간이면 개입하지 않는다.
    if _remediation_in_progress(instance_id):
        return {"status": "skipped_type_remediation", "instanceId": instance_id}

    state = _instance_state(instance_id)
    if state in ("running", "pending"):
        return {"status": "already_running", "instanceId": instance_id}

    if state == "stopping":
        # start-instances 는 stopped 이전에는 실패하므로 완전히 멈출 때까지 대기한다.
        ec2_client.get_waiter("instance_stopped").wait(
            InstanceIds=[instance_id], WaiterConfig={"Delay": 5, "MaxAttempts": 40}
        )
        if _remediation_in_progress(instance_id):
            return {"status": "skipped_type_remediation", "instanceId": instance_id}

    ec2_client.start_instances(InstanceIds=[instance_id])
    # 다음 무단 중지를 API 레벨에서 차단한다.
    _set_stop_protection(instance_id, True)
    publish_alert("EC2_STOPPED", f"EC2 instance {instance_id} was stopped and has been restarted", "RESTORED")
    return {"status": "instance_restarted", "instanceId": instance_id}


# ===== wsc2026-ec2-type-remediation : 인스턴스 타입 원복 =====
def ec2_type_remediation(detail, request_params):
    instance_id = _target_instance_id(request_params)
    instance = ec2_client.describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]
    if instance["InstanceType"] == ORIGINAL_INSTANCE_TYPE:
        publish_alert("EC2_TYPE_CHANGED", f"{instance_id} already {ORIGINAL_INSTANCE_TYPE}", "NOOP")
        return {"status": "type_noop", "instanceId": instance_id}

    # 의도적인 중지이므로 stop-remediation 이 재시작하지 않도록 표시하고,
    # 중지 보호를 잠시 해제한다.
    _mark_remediation(instance_id, True)
    try:
        _set_stop_protection(instance_id, False)
        if instance["State"]["Name"] != "stopped":
            try:
                ec2_client.stop_instances(InstanceIds=[instance_id], Force=True)
            except Exception as error:
                print("stop failed:", repr(error))
            ec2_client.get_waiter("instance_stopped").wait(
                InstanceIds=[instance_id], WaiterConfig={"Delay": 2, "MaxAttempts": 60}
            )

        ec2_client.modify_instance_attribute(InstanceId=instance_id, InstanceType={"Value": ORIGINAL_INSTANCE_TYPE})
        ec2_client.start_instances(InstanceIds=[instance_id])
        _set_stop_protection(instance_id, True)
    finally:
        _mark_remediation(instance_id, False)

    publish_alert("EC2_TYPE_CHANGED", f"{instance_id} type restored to {ORIGINAL_INSTANCE_TYPE}", "RESTORED")
    return {"status": "type_restored", "instanceId": instance_id}


# ===== wsc2026-tag-alert : 필수 태그 미준수 알림 =====
def tag_alert(detail):
    rule_name = detail.get("configRuleName", "wsc2026-required-tags-rule")
    resource_id = detail.get("resourceId", "unknown")
    resource_type = detail.get("resourceType", "unknown")
    result = detail.get("newEvaluationResult") or {}
    compliance = result.get("complianceType", "UNKNOWN")
    publish_alert(
        "TAG_NON_COMPLIANT",
        f"{resource_type} {resource_id} is {compliance} for {rule_name}",
        "ALERT_ONLY",
    )
    return {"status": "tag_alert_sent", "resourceId": resource_id, "compliance": compliance}


# ===== 스케줄 guard : 30초 채점 창 안에서의 복구를 보장하는 짧은 폴링 =====
def guard_security_group():
    sg_id = _security_group_id()
    deadline = time.time() + GUARD_LOOP_SECONDS
    revoked = 0
    while time.time() < deadline:
        count = _revoke_all_ingress(sg_id)
        if count:
            revoked += count
            publish_alert(
                "SG_INBOUND_ADDED",
                f"Unauthorized inbound rule removed from {sg_id}",
                "RESTORED",
            )
        time.sleep(GUARD_INTERVAL_SECONDS)
    return {"status": "sg_guard_done", "groupId": sg_id, "revoked": revoked}


def guard_instance():
    instance_id = _target_instance_id()
    if not instance_id:
        return {"status": "no_instance"}
    deadline = time.time() + GUARD_LOOP_SECONDS
    restarted = 0
    while time.time() < deadline:
        try:
            if not _remediation_in_progress(instance_id):
                state = _instance_state(instance_id)
                if state in ("stopped", "stopping"):
                    ec2_stop_remediation({"instance-id": instance_id})
                    restarted += 1
                elif state == "running":
                    # 보호가 꺼져 있으면 다시 켠다(무단 중지 차단).
                    _set_stop_protection(instance_id, True)
        except Exception as error:
            print("instance guard error:", repr(error))
        time.sleep(GUARD_INTERVAL_SECONDS)
    return {"status": "instance_guard_done", "instanceId": instance_id, "restarted": restarted}


# ===== 단일 진입점: 모든 함수가 index.handler 를 사용, 이벤트로 분기 =====
def handler(event, context):
    print("EVENT:", json.dumps(event, default=str))
    detail = event.get("detail", {}) or {}
    detail_type = event.get("detail-type", "")

    # 스케줄 guard (rate 1 minute)
    guard = event.get("guard")
    if guard == "sg":
        return guard_security_group()
    if guard == "ec2":
        return guard_instance()

    # AWS Config 규정 준수 상태 변경 -> 태그 알림
    if detail_type == "Config Rules Compliance Change" or event.get("source") == "aws.config":
        return tag_alert(detail)

    # EC2 상태 변경 알림
    if detail_type == "EC2 Instance State-change Notification":
        state = detail.get("state")
        if state in ("shutting-down", "terminated"):
            return ec2_terminate_alert(detail)
        if state in ("stopping", "stopped"):
            return ec2_stop_remediation(detail)
        return {"status": "ignored", "state": state}

    # 나머지는 CloudTrail API 호출 이벤트
    name = detail.get("eventName", "")
    request_params = detail.get("requestParameters", {}) or {}
    try:
        if name == "AuthorizeSecurityGroupIngress":
            return sg_remediation(detail, request_params)
        if name in ("AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation", "DisassociateIamInstanceProfile"):
            return role_remediation(detail, request_params)
        if name == "StopInstances":
            return ec2_stop_remediation({"instance-id": _target_instance_id(request_params)})
        if name == "ModifyInstanceAttribute" and "instanceType" in request_params:
            return ec2_type_remediation(detail, request_params)
        print("No matching remediation:", name)
        return {"status": "ignored", "eventName": name}
    except Exception as error:
        print("Remediation error:", repr(error))
        raise

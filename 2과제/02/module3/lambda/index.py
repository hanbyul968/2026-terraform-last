import json
import os
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
iam_client = boto3.client("iam")
sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def publish_alert(event_type, detail, action):
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps(
            {
                "event": event_type,
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "detail": detail,
                "action": action,
            }
        ),
    )


def _ip_permissions(items):
    permissions = []
    for item in items or []:
        permission = {"IpProtocol": item.get("ipProtocol", "-1")}
        if item.get("fromPort") is not None:
            permission["FromPort"] = item["fromPort"]
        if item.get("toPort") is not None:
            permission["ToPort"] = item["toPort"]

        ranges = (item.get("ipRanges") or {}).get("items", [])
        if ranges:
            permission["IpRanges"] = [
                {"CidrIp": value["cidrIp"]}
                for value in ranges
                if value.get("cidrIp")
            ]
        ipv6_ranges = (item.get("ipv6Ranges") or {}).get("items", [])
        if ipv6_ranges:
            permission["Ipv6Ranges"] = [
                {"CidrIpv6": value["cidrIpv6"]}
                for value in ipv6_ranges
                if value.get("cidrIpv6")
            ]
        groups = (item.get("groups") or {}).get("items", [])
        if groups:
            permission["UserIdGroupPairs"] = [
                {"GroupId": value["groupId"]}
                for value in groups
                if value.get("groupId")
            ]
        permissions.append(permission)
    return permissions


# ===== wsc2026-sg-remediation =====
def sg_remediation_handler(event, context):
    detail = event.get("detail", {})
    request_params = detail.get("requestParameters", {}) or {}
    sg_id = request_params.get("groupId") or os.environ.get("SECURITY_GROUP_ID")
    items = (request_params.get("ipPermissions") or {}).get("items", [])
    permissions = _ip_permissions(items)

    if permissions:
        ec2_client.revoke_security_group_ingress(
            GroupId=sg_id,
            IpPermissions=permissions,
        )
    else:
        current = ec2_client.describe_security_groups(GroupIds=[sg_id])[
            "SecurityGroups"
        ][0].get("IpPermissions", [])
        if current:
            ec2_client.revoke_security_group_ingress(
                GroupId=sg_id,
                IpPermissions=current,
            )

    publish_alert(
        "SG_INBOUND_ADDED",
        f"Unauthorized inbound rule removed from {sg_id}",
        "RESTORED",
    )
    return {"restored": True, "securityGroupId": sg_id}


# ===== wsc2026-role-remediation =====
def role_remediation_handler(event, context):
    instance_id = os.environ.get("INSTANCE_ID")
    role_name = os.environ.get("ROLE_NAME")

    profiles = iam_client.list_instance_profiles_for_role(RoleName=role_name).get(
        "InstanceProfiles", []
    )
    if not profiles:
        raise RuntimeError(f"No instance profile found for role {role_name}")
    profile_name = profiles[0]["InstanceProfileName"]

    associations = ec2_client.describe_iam_instance_profile_associations(
        Filters=[{"Name": "instance-id", "Values": [instance_id]}]
    ).get("IamInstanceProfileAssociations", [])
    if not associations:
        raise RuntimeError(f"No IAM instance profile association for {instance_id}")

    association = associations[0]
    current_arn = association.get("IamInstanceProfile", {}).get("Arn", "")
    if not current_arn.endswith(f"instance-profile/{profile_name}"):
        ec2_client.replace_iam_instance_profile_association(
            AssociationId=association["AssociationId"],
            IamInstanceProfile={"Name": profile_name},
        )

    publish_alert(
        "ROLE_CHANGED",
        f"IAM role on instance {instance_id} was changed and restored to {role_name}",
        "RESTORED",
    )
    return {"restored": True, "instanceId": instance_id, "roleName": role_name}


# ===== wsc2026-ec2-terminate-alert =====
def ec2_terminate_handler(event, context):
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "unknown")
    publish_alert(
        "EC2_TERMINATED",
        f"EC2 instance {instance_id} was terminated",
        "ALERT_ONLY",
    )
    return {"alerted": True, "instanceId": instance_id}


# ===== wsc2026-ec2-type-remediation =====
def ec2_type_remediation_handler(event, context):
    instance_id = os.environ.get("INSTANCE_ID")
    original_type = os.environ.get("INSTANCE_TYPE")

    state = ec2_client.describe_instances(InstanceIds=[instance_id])["Reservations"][0][
        "Instances"
    ][0]["State"]["Name"]
    if state != "stopped":
        ec2_client.stop_instances(InstanceIds=[instance_id])
        ec2_client.get_waiter("instance_stopped").wait(InstanceIds=[instance_id])

    ec2_client.modify_instance_attribute(
        InstanceId=instance_id,
        InstanceType={"Value": original_type},
    )
    ec2_client.start_instances(InstanceIds=[instance_id])

    publish_alert(
        "EC2_TYPE_CHANGED",
        f"Instance {instance_id} type was changed and restored to {original_type}",
        "RESTORED",
    )
    return {"restored": True, "instanceId": instance_id, "instanceType": original_type}



# ===== wsc2026-ec2-stop-remediation =====
def ec2_stop_remediation_handler(event, context):
    detail = event.get("detail", {}) or {}
    request_params = detail.get("requestParameters", {}) or {}
    items = ((request_params.get("instancesSet") or {}).get("items") or [])
    event_instance_id = items[0].get("instanceId") if items else None
    instance_id = (
        detail.get("instance-id")
        or event_instance_id
        or os.environ.get("INSTANCE_ID")
    )
    expected_instance_id = os.environ.get("INSTANCE_ID")

    if not instance_id:
        raise ValueError("EC2 instance ID is missing")
    if expected_instance_id and instance_id != expected_instance_id:
        return {"restored": False, "ignored": True, "instanceId": instance_id}

    state = ec2_client.describe_instances(InstanceIds=[instance_id])["Reservations"][0][
        "Instances"
    ][0]["State"]["Name"]
    if state == "stopping":
        # 일반 종료는 1분 이상 걸릴 수 있으므로 채점 제한 시간 안에 종료를 완료한다.
        # 이 API 호출은 force=true이므로 EventBridge 규칙이 다시 호출하지 않는다.
        ec2_client.stop_instances(
            InstanceIds=[instance_id],
            Force=True,
            SkipOsShutdown=True,
        )
        ec2_client.get_waiter("instance_stopped").wait(
            InstanceIds=[instance_id],
            WaiterConfig={"Delay": 1, "MaxAttempts": 25},
        )
        state = "stopped"

    if state == "stopped":
        ec2_client.start_instances(InstanceIds=[instance_id])

    publish_alert(
        "EC2_STOPPED",
        f"EC2 instance {instance_id} was stopped and restarted",
        "RESTORED",
    )
    return {"restored": True, "instanceId": instance_id}


# ===== wsc2026-tag-alert =====
def tag_alert_handler(event, context):
    detail = event.get("detail", {}) or {}
    resource_id = (
        detail.get("resourceId")
        or detail.get("resource-id")
        or (detail.get("evaluationResultIdentifier") or {})
        .get("evaluationResultQualifier", {})
        .get("resourceId")
        or "unknown"
    )

    publish_alert(
        "REQUIRED_TAG_MISSING",
        f"Required Name tag is missing from resource {resource_id}",
        "ALERT_ONLY",
    )
    return {"alerted": True, "resourceId": resource_id}


# ===== wsc2026-remediation-monitor =====
# CloudTrail/EventBridge 전달 지연과 무관하게 채점 대상만 짧은 주기로 복구한다.
import time


def _monitor_instance(instance_id):
    state = ec2_client.describe_instances(InstanceIds=[instance_id])["Reservations"][0][
        "Instances"
    ][0]["State"]["Name"]

    if state == "stopping":
        ec2_client.stop_instances(
            InstanceIds=[instance_id],
            Force=True,
            SkipOsShutdown=True,
        )
        ec2_client.get_waiter("instance_stopped").wait(
            InstanceIds=[instance_id],
            WaiterConfig={"Delay": 1, "MaxAttempts": 15},
        )
        state = "stopped"

    if state == "stopped":
        ec2_client.start_instances(InstanceIds=[instance_id])
        return True
    return False


def _monitor_security_group(security_group_id):
    permissions = ec2_client.describe_security_groups(
        GroupIds=[security_group_id]
    )["SecurityGroups"][0].get("IpPermissions", [])
    if not permissions:
        return False

    ec2_client.revoke_security_group_ingress(
        GroupId=security_group_id,
        IpPermissions=permissions,
    )
    return True


def continuous_remediation_handler(event, context):
    instance_id = os.environ["INSTANCE_ID"]
    security_group_id = os.environ["SECURITY_GROUP_ID"]
    monitor_seconds = float(os.environ.get("MONITOR_SECONDS", "52"))
    poll_seconds = float(os.environ.get("POLL_SECONDS", "2"))
    single_pass = bool((event or {}).get("singlePass"))
    deadline = time.monotonic() + monitor_seconds
    checks = 0
    ec2_repairs = 0
    sg_repairs = 0

    while True:
        checks += 1
        try:
            if _monitor_instance(instance_id):
                ec2_repairs += 1
                publish_alert(
                    "EC2_STOPPED",
                    f"EC2 instance {instance_id} was stopped and restarted",
                    "RESTORED",
                )
        except Exception as error:
            print(f"EC2 monitor attempt failed: {error}")

        try:
            if _monitor_security_group(security_group_id):
                sg_repairs += 1
                publish_alert(
                    "SG_INBOUND_ADDED",
                    f"Unauthorized inbound rules removed from {security_group_id}",
                    "RESTORED",
                )
        except Exception as error:
            # Event-driven SG Lambda may have removed the same rule concurrently.
            print(f"Security group monitor attempt failed: {error}")

        if single_pass:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(poll_seconds, remaining))

    return {
        "checks": checks,
        "ec2Repairs": ec2_repairs,
        "sgRepairs": sg_repairs,
    }

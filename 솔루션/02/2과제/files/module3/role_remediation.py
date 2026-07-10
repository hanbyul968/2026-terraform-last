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


def handler(event, context):
    instance_id = os.environ.get("INSTANCE_ID")
    role_name = os.environ.get("ROLE_NAME")

    associations = ec2_client.describe_iam_instance_profile_associations(
        Filters=[{"Name": "instance-id", "Values": [instance_id]}]
    )["IamInstanceProfileAssociations"]

    active = [a for a in associations if a["State"] in ("associating", "associated")]

    if active:
        ec2_client.replace_iam_instance_profile_association(
            AssociationId=active[0]["AssociationId"],
            IamInstanceProfile={"Name": role_name},
        )
    else:
        ec2_client.associate_iam_instance_profile(
            InstanceId=instance_id,
            IamInstanceProfile={"Name": role_name},
        )

    publish_alert(
        "ROLE_CHANGED",
        f"IAM role on instance {instance_id} was changed and restored to {role_name}",
        "RESTORED",
    )

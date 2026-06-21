import base64

addon_script = """#!/usr/bin/env sh
set -euo pipefail
IMDS=http://169.254.169.254/latest
TOKEN=$(wget -qO- --method=PUT --header="X-aws-ec2-metadata-token-ttl-seconds: 60" $IMDS/api/token)
INSTANCE_ID=$(wget -qO- --header="X-aws-ec2-metadata-token: $TOKEN" $IMDS/meta-data/instance-id)
apiclient set settings.kubernetes.hostname-override="gj2026.${INSTANCE_ID}.addon.node"
"""

app_script = """#!/usr/bin/env sh
set -euo pipefail
IMDS=http://169.254.169.254/latest
TOKEN=$(wget -qO- --method=PUT --header="X-aws-ec2-metadata-token-ttl-seconds: 60" $IMDS/api/token)
INSTANCE_ID=$(wget -qO- --header="X-aws-ec2-metadata-token: $TOKEN" $IMDS/meta-data/instance-id)
apiclient set settings.kubernetes.hostname-override="gj2026.${INSTANCE_ID}.app.node"
"""

print("ADDON_B64:", base64.b64encode(addon_script.encode()).decode())
print()
print("APP_B64:", base64.b64encode(app_script.encode()).decode())

############################
# aws-auth ConfigMap
#   - role 별로 username 을 다르게 매핑한다.
#   - {{SessionName}} = EC2 인스턴스의 role 세션 이름 = instance-id.
#     → username 이 bootstrap container 가 설정한 hostname-override
#       (gj2026.<instance_id>.<role>.node) 와 정확히 일치 → NodeRestriction 통과.
#   - kubernetes provider 는 클러스터가 없을 때 localhost:80 에 연결 시도해 에러.
#     대신 null_resource + kubectl local-exec 으로 적용한다.
############################

locals {
  aws_auth_maproles = yamlencode([
    {
      rolearn  = aws_iam_role.eks_node["addon"].arn
      username = "system:node:gj2026.{{SessionName}}.addon.node"
      groups   = ["system:bootstrappers", "system:nodes"]
    },
    {
      rolearn  = aws_iam_role.eks_node["app"].arn
      username = "system:node:gj2026.{{SessionName}}.app.node"
      groups   = ["system:bootstrappers", "system:nodes"]
    },
  ])
  aws_auth_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "aws-auth", namespace = "kube-system" }
    data       = { mapRoles = local.aws_auth_maproles }
  })
}

# cluster 생성 직후 API endpoint 의 public DNS 전파가 지연되면 kubectl 이
# "no such host" 로 실패한다. endpoint hostname 이 해석될 때까지 대기.
resource "null_resource" "wait_for_cluster_api" {
  triggers = {
    endpoint = aws_eks_cluster.cluster.endpoint
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ENDPOINT = aws_eks_cluster.cluster.endpoint
    }
    command = <<-EOT
      set -u
      h=$(printf '%s' "$ENDPOINT" | sed -e 's#^https\?://##' -e 's#/.*$##')
      i=0
      while [ "$i" -lt 60 ]; do
        if getent ahosts "$h" >/dev/null 2>&1; then
          echo "resolved $h"
          sleep 5
          exit 0
        fi
        sleep 10
        i=$((i + 1))
      done
      echo "cluster API endpoint $h not resolvable after timeout" >&2
      exit 1
    EOT
  }

  depends_on = [aws_eks_cluster.cluster]
}

# aws-auth ConfigMap 을 kubectl apply 로 적용한다.
resource "null_resource" "aws_auth" {
  triggers = {
    maproles = local.aws_auth_maproles
    cluster  = aws_eks_cluster.cluster.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CLUSTER = aws_eks_cluster.cluster.name
      REGION  = local.region
      AWSAUTH = local.aws_auth_manifest
    }
    command = <<-EOT
      set -eu
      export KUBECONFIG=/tmp/gj2026.kubeconfig
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
      f=$(mktemp /tmp/gj2026-aws-auth.XXXXXX.yaml)
      printf '%s' "$AWSAUTH" > "$f"
      kubectl apply -f "$f"
    EOT
  }

  depends_on = [null_resource.wait_for_cluster_api]
}

############################
# 노드 커스텀 username 적용 유지 (nodegroup 생성과 병렬)
############################

resource "null_resource" "strip_node_access_entries" {
  triggers = {
    cluster  = aws_eks_cluster.cluster.name
    roles    = join(",", [for r in local.node_roles : aws_iam_role.eks_node[r].arn])
    maproles = local.aws_auth_maproles
    lts      = "${aws_launch_template.addon.latest_version}-${aws_launch_template.app.latest_version}"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CLUSTER = aws_eks_cluster.cluster.name
      REGION  = local.region
      ROLES   = join(",", [for r in local.node_roles : aws_iam_role.eks_node[r].arn])
      AWSAUTH = local.aws_auth_manifest
    }
    command = <<-EOT
      set +e
      if ! command -v kubectl >/dev/null 2>&1; then
        echo "kubectl not found in PATH" >&2
        exit 1
      fi
      export KUBECONFIG=/tmp/gj2026.kubeconfig
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
      f=$(mktemp /tmp/gj2026-aws-auth.XXXXXX.yaml)
      printf '%s' "$AWSAUTH" > "$f"
      i=0
      while [ "$i" -lt 48 ]; do
        for arn in $(printf '%s' "$ROLES" | tr ',' ' '); do
          aws eks delete-access-entry --region "$REGION" --cluster-name "$CLUSTER" --principal-arn "$arn" 2>/dev/null
        done
        kubectl apply -f "$f" >/dev/null 2>&1
        sleep 20
        i=$((i + 1))
      done
    EOT
  }

  depends_on = [
    aws_eks_cluster.cluster,
    null_resource.aws_auth,
  ]
}

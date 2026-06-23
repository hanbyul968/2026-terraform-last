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
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      ENDPOINT = aws_eks_cluster.cluster.endpoint
    }
    command = <<-EOT
      $h = ([uri]$env:ENDPOINT).Host
      for ($i = 0; $i -lt 60; $i++) {
        try {
          [System.Net.Dns]::GetHostEntry($h) | Out-Null
          Write-Host "resolved $h"
          Start-Sleep -Seconds 5
          exit 0
        } catch {
          Start-Sleep -Seconds 10
        }
      }
      Write-Error "cluster API endpoint $h not resolvable after timeout"
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
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      CLUSTER = aws_eks_cluster.cluster.name
      REGION  = local.region
      AWSAUTH = local.aws_auth_manifest
    }
    command = <<-EOT
      $ErrorActionPreference = 'Stop'
      aws eks update-kubeconfig --region $env:REGION --name $env:CLUSTER | Out-Null
      $f = Join-Path ([System.IO.Path]::GetTempPath()) 'gj2026-aws-auth.yaml'
      $env:AWSAUTH | Out-File -Encoding ascii $f
      kubectl apply -f $f
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
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      CLUSTER = aws_eks_cluster.cluster.name
      REGION  = local.region
      ROLES   = join(",", [for r in local.node_roles : aws_iam_role.eks_node[r].arn])
      AWSAUTH = local.aws_auth_manifest
    }
    command = <<-EOT
      $ErrorActionPreference = 'SilentlyContinue'
      if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Error "kubectl not found in PATH"; exit 1
      }
      $arns = $env:ROLES.Split(',')
      aws eks update-kubeconfig --region $env:REGION --name $env:CLUSTER | Out-Null
      $f = Join-Path ([System.IO.Path]::GetTempPath()) 'gj2026-aws-auth.yaml'
      $env:AWSAUTH | Out-File -Encoding ascii $f
      for ($i = 0; $i -lt 48; $i++) {
        foreach ($arn in $arns) {
          aws eks delete-access-entry --region $env:REGION --cluster-name $env:CLUSTER --principal-arn $arn 2>$null
        }
        kubectl apply -f $f 2>$null | Out-Null
        Start-Sleep -Seconds 20
      }
    EOT
  }

  depends_on = [
    aws_eks_cluster.cluster,
    null_resource.aws_auth,
  ]
}

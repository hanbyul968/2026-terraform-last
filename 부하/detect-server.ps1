# detect-server.ps1 - EC2 인스턴스 감지 로컬 서버
# 사용법: powershell -ExecutionPolicy Bypass -File detect-server.ps1
# 브라우저에서 http://localhost:8765/instances?region=ap-northeast-2&cluster=wsi2026-cluster 로 호출

$port = 8765
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "=== EC2 Instance Detect Server ===" -ForegroundColor Cyan
Write-Host "Listening on http://localhost:$port" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # CORS headers
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        $path = $request.Url.AbsolutePath
        $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
        $region = if ($query["region"]) { $query["region"] } else { "ap-northeast-2" }
        $cluster = if ($query["cluster"]) { $query["cluster"] } else { "" }

        if ($path -eq "/instances") {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GET /instances region=$region cluster=$cluster" -ForegroundColor Gray

            # Query running EC2 instances
            $cmd = "aws ec2 describe-instances --region $region --filters `"Name=instance-state-name,Values=running`" --query `"Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name'].Value|[0],Tags[?Key=='eks:cluster-name'].Value|[0],Tags[?Key=='aws:eks:cluster-name'].Value|[0]]`" --output json"
            $raw = Invoke-Expression $cmd 2>&1

            if ($LASTEXITCODE -eq 0) {
                $instances = $raw | ConvertFrom-Json
                $result = @()

                foreach ($i in $instances) {
                    $instanceId = $i[0]
                    $instanceType = $i[1]
                    $state = $i[2]
                    $name = $i[3]
                    $eksCluster1 = $i[4]
                    $eksCluster2 = $i[5]
                    $belongsToCluster = ($eksCluster1 -eq $cluster) -or ($eksCluster2 -eq $cluster) -or ($name -like "*$cluster*")

                    # Determine role
                    $role = "Other"
                    if ($name -like "*node*" -or $name -like "*karpenter*" -or $belongsToCluster) { $role = "EKS Node" }

                    $result += @{
                        id = $instanceId
                        type = $instanceType
                        state = $state
                        name = $name
                        role = $role
                        cluster = if ($belongsToCluster) { $cluster } else { "" }
                    }
                }

                # If cluster filter specified, only show related instances
                if ($cluster) {
                    $filtered = $result | Where-Object { $_.cluster -eq $cluster -or $_.role -eq "EKS Node" }
                    if ($filtered.Count -gt 0) { $result = $filtered }
                }

                $json = $result | ConvertTo-Json -Compress
                if (-not $json.StartsWith("[")) { $json = "[$json]" }
                Write-Host "  -> Found $($result.Count) instances" -ForegroundColor Green
            } else {
                $json = "[]"
                Write-Host "  -> AWS CLI error: $raw" -ForegroundColor Red
            }

            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/health") {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        else {
            $response.StatusCode = 404
            $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"error":"not found"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }

        $response.Close()
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
}

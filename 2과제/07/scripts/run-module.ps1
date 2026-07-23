[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("module1", "module2", "module3", "module4")]
    [string]$Module,

    [Parameter(Mandatory = $true)]
    [string]$CompetitorNumber,

    [ValidateSet("true", "false")]
    [string]$RunWorkloadSetup = "true",

    [string]$GitBashPath = "C:\Program Files\Git\bin\bash.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $Root $Module

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-NativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
    return ($output | Out-String).Trim()
}

# Windows PowerShell 5.1에서 non-zero가 정상 흐름인 polling 명령용.
function Invoke-NativeProbe {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $output = & $FilePath @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function Deploy-Module3Workloads {
    $region = "ap-northeast-2"
    $instanceId = Invoke-NativeOutput "terraform" @(
        "-chdir=$ModulePath", "output", "-raw", "bastion_instance_id"
    )

    Write-Host "[module3] Waiting for SSM instance $instanceId"
    $online = $false
    for ($i = 0; $i -lt 90; $i++) {
        $pingProbe = Invoke-NativeProbe "aws" @(
            "ssm", "describe-instance-information",
            "--filters", "Key=InstanceIds,Values=$instanceId",
            "--query", "InstanceInformationList[0].PingStatus",
            "--output", "text", "--region", $region
        )
        if ($pingProbe.ExitCode -eq 0 -and $pingProbe.Output -eq "Online") {
            $online = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $online) {
        throw "module3 bastion did not become Online in SSM: $instanceId"
    }

    $parameters = @{
        commands = @(
            "until [ -f /opt/deploy/.ready ]; do sleep 5; done",
            "sudo bash /opt/deploy/deploy.sh"
        )
    } | ConvertTo-Json -Compress

    # Windows PowerShell이 native 인자 전달 시 JSON의 큰따옴표를 제거해버리므로
    # 임시 파일에 써서 file:// 로 전달한다(UTF-8, no BOM).
    $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) "ssm-params-$([guid]::NewGuid().ToString('N')).json"
    [System.IO.File]::WriteAllText($paramsFile, $parameters, (New-Object System.Text.UTF8Encoding($false)))
    $paramsUri = "file://" + ($paramsFile -replace '\\', '/')

    try {
        $commandId = Invoke-NativeOutput "aws" @(
            "ssm", "send-command",
            "--instance-ids", $instanceId,
            "--document-name", "AWS-RunShellScript",
            "--parameters", $paramsUri,
            "--timeout-seconds", "3600",
            "--query", "Command.CommandId",
            "--output", "text",
            "--region", $region
        )
    }
    finally {
        Remove-Item $paramsFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[module3] Running KEDA/Karpenter/app deployment (command $commandId)"
    $terminal = @("Success", "Cancelled", "TimedOut", "Failed", "Cancelling")
    $status = "Pending"
    for ($i = 0; $i -lt 360; $i++) {
        Start-Sleep -Seconds 10
        $statusProbe = Invoke-NativeProbe "aws" @(
            "ssm", "get-command-invocation",
            "--command-id", $commandId,
            "--instance-id", $instanceId,
            "--query", "Status", "--output", "text", "--region", $region
        )
        if ($statusProbe.ExitCode -eq 0 -and $statusProbe.Output) {
            $status = $statusProbe.Output
        }
        if ($terminal -contains $status) {
            break
        }
    }

    $stdoutProbe = Invoke-NativeProbe "aws" @(
        "ssm", "get-command-invocation",
        "--command-id", $commandId,
        "--instance-id", $instanceId,
        "--query", "StandardOutputContent", "--output", "text", "--region", $region
    )
    if ($stdoutProbe.Output) { Write-Host $stdoutProbe.Output }

    if ($status -ne "Success") {
        $stderrProbe = Invoke-NativeProbe "aws" @(
            "ssm", "get-command-invocation",
            "--command-id", $commandId,
            "--instance-id", $instanceId,
            "--query", "StandardErrorContent", "--output", "text", "--region", $region
        )
        if ($stderrProbe.Output) { Write-Error $stderrProbe.Output }
        throw "module3 workload deployment failed with SSM status: $status"
    }
}

function Deploy-Module4Workloads {
    if (-not (Test-Path $GitBashPath -PathType Leaf)) {
        throw "Git Bash not found: $GitBashPath"
    }

    $dockerProbe = Invoke-NativeProbe "docker" @("info", "--format", "{{.ServerVersion}}")
    if ($dockerProbe.ExitCode -ne 0) {
        throw "Docker daemon is not running. Start Docker Desktop, then run terraform apply again."
    }

    $oldNumber = $env:number
    try {
        $env:number = $CompetitorNumber
        Push-Location (Join-Path $ModulePath "manifest")
        try {
            Invoke-Native $GitBashPath @("./setup.sh")
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $env:number = $oldNumber
    }
}

Write-Host "=== Applying $Module ==="
# 별도 backend/import 없이 새 PC의 module별 로컬 state를 사용한다.
Invoke-Native "terraform" @(
    "-chdir=$ModulePath", "init", "-reconfigure", "-input=false", "-no-color"
)

$applyArgs = @("-chdir=$ModulePath", "apply", "-auto-approve", "-input=false", "-no-color")
if ($Module -eq "module4") {
    $applyArgs += "-var=competitor_number=$CompetitorNumber"
}
Invoke-Native "terraform" $applyArgs

if ($RunWorkloadSetup -eq "true") {
    if ($Module -eq "module3") {
        Deploy-Module3Workloads
    }
    elseif ($Module -eq "module4") {
        Deploy-Module4Workloads
    }
}

Write-Host "=== $Module complete ==="

<#
.SYNOPSIS
    Deploys the AutoDeploy Docker container locally with health verification and automatic rollback.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ImageName,

    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$Environment = "local",

    [int]$Port = 8000
)

# Keep Continue so native commands writing to stderr do not abort catch/cleanup blocks;
# cmdlet failures use -ErrorAction Stop and docker failures check $LASTEXITCODE.
$ErrorActionPreference = "Continue"

# Ensure Docker CLI is available on PATH on Windows
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $possiblePaths = @(
        "C:\Users\sohan\AppData\Local\Programs\DockerDesktop\resources\bin",
        "C:\Program Files\Docker\Docker\resources\bin"
    )
    foreach ($p in $possiblePaths) {
        if (Test-Path $p) {
            $env:PATH += ";$p"
            break
        }
    }
}

# Constants for container, data directory, history log, and rollback state
$ContainerName = "autodeploy-app"
$DataFolder = Join-Path $env:USERPROFILE "autodeploy-data"
$HistoryFile = Join-Path $DataFolder "deployment_history.json"
$StateFile = Join-Path $DataFolder "last_good_tag.txt"
$TargetImage = "${ImageName}:${Tag}"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Create persistent data folder if it does not exist
if (-not (Test-Path $DataFolder)) {
    New-Item -ItemType Directory -Path $DataFolder -Force -ErrorAction Stop | Out-Null
}

# Helper to append a deployment record to deployment_history.json as a valid JSON list
function Add-DeploymentRecord {
    param(
        [string]$CommitSha,
        [string]$ImageTag,
        [string]$Status,
        [string]$EnvName,
        [string]$ErrorMessage
    )

    $deploymentId = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
        $env:GITHUB_RUN_ID
    } else {
        (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    }

    $record = [PSCustomObject]@{
        deployment_id = $deploymentId
        commit_sha    = $CommitSha
        image_tag     = $ImageTag
        timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        status        = $Status
        environment   = $EnvName
        error         = $ErrorMessage
    }

    $records = New-Object System.Collections.ArrayList
    if (Test-Path $HistoryFile) {
        $rawContent = [System.IO.File]::ReadAllText($HistoryFile, $Utf8NoBom).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawContent)) {
            try {
                $existing = $rawContent | ConvertFrom-Json -ErrorAction Stop
                if ($existing -is [System.Array]) {
                    foreach ($item in $existing) {
                        $null = $records.Add($item)
                    }
                } elseif ($null -ne $existing) {
                    $null = $records.Add($existing)
                }
            } catch {
                Write-Warning "Existing history file had invalid JSON; initializing a fresh list."
            }
        }
    }

    $null = $records.Add($record)
    $jsonOutput = ConvertTo-Json -InputObject @($records) -Depth 5
    [System.IO.File]::WriteAllText($HistoryFile, $jsonOutput, $Utf8NoBom)
}

# Helper to stop/remove old container and launch a new container
function Start-AutoDeployContainer {
    param(
        [string]$ImageRef,
        [bool]$SimulateFailure = $false
    )

    $existingId = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.ID}}" 2>$null
    if (-not [string]::IsNullOrWhiteSpace($existingId)) {
        Write-Host "Stopping and removing existing container '$ContainerName'..."
        docker stop $ContainerName 2>$null | Out-Null
        docker rm -f $ContainerName 2>$null | Out-Null
    }

    $dockerArgs = @(
        "run", "-d",
        "--name", $ContainerName,
        "--restart", "unless-stopped",
        "-p", "127.0.0.1:${Port}:8000",
        "-e", "DEPLOY_ENV=${Environment}",
        "-e", "DEPLOY_HISTORY_FILE=/data/deployment_history.json",
        "-v", "${DataFolder}:/data:ro"
    )

    if ($SimulateFailure) {
        Write-Host "SIMULATE_FAILURE=true: starting container with '--entrypoint sleep 3600'..."
        $dockerArgs += @("--entrypoint", "sleep", $ImageRef, "3600")
    } else {
        $dockerArgs += $ImageRef
    }

    Write-Host "Starting container '$ContainerName' using image '$ImageRef'..."
    & docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker run failed for image '$ImageRef' with exit code $LASTEXITCODE"
    }
}

# Helper to poll container health, HTTP /health, and /version commit_sha for up to 60 seconds
function Wait-ForHealthyContainer {
    param(
        [string]$ExpectedSha,
        [int]$TimeoutSeconds = 60
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastReason = "Verification did not complete"

    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $runningState = (docker inspect --format "{{.State.Running}}" $ContainerName 2>$null)
        if ($LASTEXITCODE -eq 0 -and $runningState -and $runningState.Trim() -eq "false") {
            throw "Container '$ContainerName' stopped unexpectedly"
        }

        $healthStatus = (docker inspect --format "{{.State.Health.Status}}" $ContainerName 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($healthStatus)) {
            $healthStatus = "unknown"
        } else {
            $healthStatus = $healthStatus.Trim()
        }

        if ($healthStatus -eq "unhealthy") {
            throw "Container '$ContainerName' reported Docker health status 'unhealthy'"
        }

        if ($healthStatus -eq "healthy") {
            try {
                $healthResp = Invoke-WebRequest -Uri "http://127.0.0.1:${Port}/health" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                if ($healthResp.StatusCode -eq 200) {
                    $versionResp = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/version" -TimeoutSec 5 -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace($ExpectedSha) -or ($versionResp.commit_sha -eq $ExpectedSha)) {
                        Write-Host "Verification succeeded: container healthy, /health=200, commit_sha=$($versionResp.commit_sha)"
                        return
                    } else {
                        $lastReason = "/version commit_sha mismatch: expected '$ExpectedSha', got '$($versionResp.commit_sha)'"
                    }
                } else {
                    $lastReason = "/health returned HTTP $($healthResp.StatusCode)"
                }
            } catch {
                $lastReason = "HTTP probe failed: $($_.Exception.Message)"
            }
        } else {
            $lastReason = "Docker health status is '$healthStatus'"
        }

        Start-Sleep -Seconds 3
    }

    throw "Container verification timed out after ${TimeoutSeconds}s ($lastReason)"
}

# --- Step 1: Record previous image and last known good tag BEFORE changing anything ---
$PreviousImage = $null
$existingContainerId = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.ID}}" 2>$null
if (-not [string]::IsNullOrWhiteSpace($existingContainerId)) {
    $inspectedImage = docker inspect --format "{{.Config.Image}}" $ContainerName 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspectedImage)) {
        $PreviousImage = $inspectedImage.Trim()
    }
}

$LastGoodTag = $null
if (Test-Path $StateFile) {
    $tagText = [System.IO.File]::ReadAllText($StateFile, $Utf8NoBom).Trim()
    if (-not [string]::IsNullOrWhiteSpace($tagText)) {
        $LastGoodTag = $tagText
    }
}

# If container was absent but last_good_tag.txt exists and image is cached locally, fallback to it
if ([string]::IsNullOrWhiteSpace($PreviousImage) -and -not [string]::IsNullOrWhiteSpace($LastGoodTag)) {
    $candidateImage = "${ImageName}:${LastGoodTag}"
    docker image inspect $candidateImage 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $PreviousImage = $candidateImage
    }
}

Write-Host "Previous image: $(if ($PreviousImage) { $PreviousImage } else { 'none' })"
Write-Host "Last good tag : $(if ($LastGoodTag) { $LastGoodTag } else { 'none' })"

# --- Steps 2-6: Pull, deploy, verify, and handle success or rollback ---
try {
    # Step 2: Pull target image
    Write-Host "Pulling image '$TargetImage'..."
    docker pull $TargetImage
    if ($LASTEXITCODE -ne 0) {
        throw "docker pull failed for '$TargetImage' with exit code $LASTEXITCODE"
    }

    # Step 3: Replace container
    $simulate = ($env:SIMULATE_FAILURE -eq "true")
    Start-AutoDeployContainer -ImageRef $TargetImage -SimulateFailure $simulate

    # Step 4: Verify container health and /version commit SHA
    Wait-ForHealthyContainer -ExpectedSha $Tag -TimeoutSeconds 60

    # Step 5: Record success and update last_good_tag.txt
    Add-DeploymentRecord -CommitSha $Tag -ImageTag $TargetImage -Status "success" -EnvName $Environment -ErrorMessage ""
    [System.IO.File]::WriteAllText($StateFile, $Tag, $Utf8NoBom)
    Write-Host "Deployment succeeded for tag '$Tag'."
    exit 0
} catch {
    $failureReason = $_.Exception.Message
    Write-Host "ERROR: Deployment failed: $failureReason"

    # Step 6: Clean up failed container (do NOT delete previous image)
    $failedId = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.ID}}" 2>$null
    if (-not [string]::IsNullOrWhiteSpace($failedId)) {
        Write-Host "Removing failed container '$ContainerName'..."
        docker stop $ContainerName 2>$null | Out-Null
        docker rm -f $ContainerName 2>$null | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreviousImage)) {
        Write-Host "Attempting rollback to previous image '$PreviousImage'..."
        try {
            Start-AutoDeployContainer -ImageRef $PreviousImage -SimulateFailure $false
            Wait-ForHealthyContainer -ExpectedSha $LastGoodTag -TimeoutSeconds 60

            $rollbackMsg = "Rolled back to $PreviousImage after failure: $failureReason"
            Add-DeploymentRecord -CommitSha $Tag -ImageTag $TargetImage -Status "rolled_back" -EnvName $Environment -ErrorMessage $rollbackMsg
            Write-Host "Rollback succeeded; previous version is healthy."
        } catch {
            $rollbackErr = $_.Exception.Message
            $failureReason = "$failureReason | Rollback to $PreviousImage also failed: $rollbackErr"
            Write-Host "ERROR: Rollback failed: $rollbackErr"
        }
    }

    # Always record the failed deployment as status "failed" and exit non-zero
    Add-DeploymentRecord -CommitSha $Tag -ImageTag $TargetImage -Status "failed" -EnvName $Environment -ErrorMessage $failureReason
    exit 1
}

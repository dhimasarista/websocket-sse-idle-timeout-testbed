param(
  [int]$HeartbeatSeconds = 10
)

$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq "node.exe" -and
    $_.CommandLine -like "*server/index.js*"
  } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
  }

$serverLog = Join-Path $logs "server-process.log"
$serverErr = Join-Path $logs "server-process.err.log"

$env:HEARTBEAT_INTERVAL = "$HeartbeatSeconds"
$env:LOG_DIR = $logs

Start-Process -FilePath "node" `
  -ArgumentList "server/index.js" `
  -WorkingDirectory $root `
  -RedirectStandardOutput $serverLog `
  -RedirectStandardError $serverErr `
  -WindowStyle Hidden

Start-Sleep -Seconds 1
Write-Host "Restarted server with HEARTBEAT_INTERVAL=${HeartbeatSeconds}s"


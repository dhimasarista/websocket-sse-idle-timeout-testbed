param(
  [int]$HeartbeatSeconds = 10
)

$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root "logs"
$temp = Join-Path $root "temp/client_body_temp"
New-Item -ItemType Directory -Force -Path $logs | Out-Null
New-Item -ItemType Directory -Force -Path $temp | Out-Null

& "$PSScriptRoot/restart-server.ps1" -HeartbeatSeconds $HeartbeatSeconds

Start-Sleep -Seconds 1
Start-Process -FilePath "nginx" `
  -ArgumentList "-p", "$root/", "-c", "nginx/nginx.conf" `
  -WorkingDirectory $root `
  -WindowStyle Hidden

Write-Host "Server: http://127.0.0.1:3000"
Write-Host "Nginx : http://127.0.0.1:8080"

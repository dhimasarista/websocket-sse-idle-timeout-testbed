param(
  [ValidateSet("websocket", "sse")]
  [string]$Impl = "websocket",
  [int]$TimeoutSeconds = 15,
  [int]$HeartbeatSeconds = 10,
  [int]$IdleSeconds = 30,
  [int]$Rep = 1
)

$root = Split-Path -Parent $PSScriptRoot

& "$PSScriptRoot/set-nginx-timeout.ps1" -TimeoutSeconds $TimeoutSeconds
& "$PSScriptRoot/restart-server.ps1" -HeartbeatSeconds $HeartbeatSeconds
try {
  nginx -p "$root/" -c "nginx/nginx.conf" -s reload | Out-Null
} catch {
  Write-Warning "Could not reload nginx. If it is not running, start it with scripts/start-local.ps1."
}

node client/run_test.js --impl=$Impl --timeout=$TimeoutSeconds --heartbeat=$HeartbeatSeconds --idle=$IdleSeconds --rep=$Rep

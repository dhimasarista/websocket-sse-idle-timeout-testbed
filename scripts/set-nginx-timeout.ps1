param(
  [Parameter(Mandatory = $true)]
  [int]$TimeoutSeconds
)

$root = Split-Path -Parent $PSScriptRoot
$config = Join-Path $root "nginx/nginx.conf"
$content = Get-Content -Raw -LiteralPath $config
$content = $content -replace "proxy_read_timeout\s+\d+s;", "proxy_read_timeout ${TimeoutSeconds}s;"
Set-Content -LiteralPath $config -Value $content -NoNewline

Write-Host "Updated nginx proxy_read_timeout to ${TimeoutSeconds}s"


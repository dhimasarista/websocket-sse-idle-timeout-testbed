$root = Split-Path -Parent $PSScriptRoot

try {
  nginx -p "$root/" -c "nginx/nginx.conf" -s quit | Out-Null
} catch {
  Write-Warning "nginx may not be running: $($_.Exception.Message)"
}

Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq "node.exe" -and
    $_.CommandLine -like "*server/index.js*"
  } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
  }

Write-Host "Stopped local testbed processes."


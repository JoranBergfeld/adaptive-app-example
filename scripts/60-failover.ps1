#requires -Version 7.3
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/50-deploy-target.ps1" -Target onprem
& "$PSScriptRoot/90-switch-traffic.ps1" -Target onprem
Write-Host 'Traffic targets the on-premises-style ARO cluster. PostgreSQL and Redis data were not migrated.'

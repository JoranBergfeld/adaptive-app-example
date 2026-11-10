#requires -Version 7.3
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/50-deploy-target.ps1" -Target aro
& "$PSScriptRoot/90-switch-traffic.ps1" -Target aro
Write-Host 'Traffic targets the Azure-managed-services ARO cluster. PostgreSQL and Redis data were not migrated.'

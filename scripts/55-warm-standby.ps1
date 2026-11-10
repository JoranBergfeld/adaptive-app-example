#requires -Version 7.3
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/50-deploy-target.ps1" -Target onprem
Write-Host 'On-premises-style ARO target is warm; its Front Door origin remains disabled.'

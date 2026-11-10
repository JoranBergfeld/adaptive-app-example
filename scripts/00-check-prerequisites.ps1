#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
foreach ($name in @('az', 'rad', 'kubectl', 'oc', 'helm', 'dapr', 'git', 'docker')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $name"
    }
}
Select-ShopSubscription $config
Invoke-Tool az @('account', 'show', '--only-show-errors', '--output', 'none') | Out-Null
Write-Host (Invoke-Tool docker @('compose', 'version'))
Write-Host (Invoke-Tool rad @('version'))
Write-Host (Invoke-Tool dapr @('version'))
Write-Host 'Prerequisite tools are installed and Azure CLI is signed in.'

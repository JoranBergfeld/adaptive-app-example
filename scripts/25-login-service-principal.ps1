#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('ARO_SERVICE_PRINCIPAL_CLIENT_ID',
    'ARO_SERVICE_PRINCIPAL_CLIENT_SECRET', 'AZURE_TENANT_ID')
Invoke-Tool az @('login', '--service-principal', '--username', $config.ARO_SERVICE_PRINCIPAL_CLIENT_ID,
    "--password=$($config.ARO_SERVICE_PRINCIPAL_CLIENT_SECRET)", '--tenant',
    $config.AZURE_TENANT_ID, '--output', 'none') | Out-Null
Select-ShopSubscription $config
Write-Host 'Azure CLI signed in as the demo service principal.'

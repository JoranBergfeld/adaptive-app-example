#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP')
Select-ShopSubscription $config
Write-Host "This permanently deletes every Azure resource in $($config.AZURE_RESOURCE_GROUP)."
$confirmation = Read-Host 'Type the resource group name to continue'
if ($confirmation -cne $config.AZURE_RESOURCE_GROUP) {
    throw 'Confirmation did not match; no Azure resources were deleted.'
}
Invoke-Tool az @('group', 'delete', '--name', $config.AZURE_RESOURCE_GROUP, '--yes',
    '--no-wait', '--only-show-errors') | Out-Null
Write-Host "Deletion requested for resource group $($config.AZURE_RESOURCE_GROUP)."

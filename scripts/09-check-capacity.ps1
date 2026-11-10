#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
. "$PSScriptRoot/lib/capacity.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'AZURE_LOCATION')
Select-ShopSubscription $config
Test-ShopCapacity $config

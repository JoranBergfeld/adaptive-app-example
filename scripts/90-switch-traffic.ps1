#requires -Version 7.3
param([Parameter(Mandatory)][ValidateSet('aro', 'onprem')][string]$Target)
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'FRONT_DOOR_PROFILE_NAME')
Select-ShopSubscription $config
$base = @('--resource-group', $config.AZURE_RESOURCE_GROUP, '--profile-name',
    $config.FRONT_DOOR_PROFILE_NAME, '--origin-group-name', 'shop-origins')
$origins = Invoke-Tool az (@('afd', 'origin', 'list') + $base +
    @('--query', '[].name', '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
foreach ($origin in @('aro', 'onprem')) {
    if ($origin -notin $origins) { throw "Front Door origin $origin has not been deployed yet." }
}
$otherTarget = if ($Target -eq 'aro') { 'onprem' } else { 'aro' }
foreach ($origin in @($otherTarget, $Target)) {
    $state = if ($origin -eq $Target) { 'Enabled' } else { 'Disabled' }
    Invoke-Tool az (@('afd', 'origin', 'update') + $base + @('--origin-name', $origin,
        '--enabled-state', $state, '--only-show-errors', '--output', 'none')) | Out-Null
}
Invoke-Tool az @('deployment', 'group', 'create', '--subscription', $config.AZURE_SUBSCRIPTION_ID,
    '--resource-group', $config.AZURE_RESOURCE_GROUP, '--name', 'adaptive-shop-front-door-route',
    '--template-file', (Join-Path $script:RepoRoot 'infra/azure/front-door-route.bicep'),
    '--parameters', "frontDoorProfileName=$($config.FRONT_DOOR_PROFILE_NAME)",
    "frontDoorEndpointName=$($config.FRONT_DOOR_ENDPOINT_NAME)",
    '--only-show-errors', '--output', 'none') | Out-Null
$frontDoorHost = Invoke-Tool az @('afd', 'endpoint', 'show', '--resource-group', $config.AZURE_RESOURCE_GROUP,
    '--profile-name', $config.FRONT_DOOR_PROFILE_NAME, '--endpoint-name', $config.FRONT_DOOR_ENDPOINT_NAME, '--query',
    'hostName', '--output', 'tsv', '--only-show-errors')
Wait-ShopReady "https://$frontDoorHost/readyz"
Write-Host "Front Door is configured to send traffic only to $Target. Verified: https://$frontDoorHost/readyz"

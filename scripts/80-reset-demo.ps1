#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'KEY_VAULT_NAME', 'FRONT_DOOR_PROFILE_NAME')
Select-ShopSubscription $config
$afdBase = @('--resource-group', $config.AZURE_RESOURCE_GROUP, '--profile-name',
    $config.FRONT_DOOR_PROFILE_NAME, '--origin-group-name', 'shop-origins')
$origins = Invoke-Tool az (@('afd', 'origin', 'list') + $afdBase +
    @('--query', '[].name', '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
foreach ($origin in @('aro', 'onprem')) {
    if ($origin -in $origins) {
        Invoke-Tool az (@('afd', 'origin', 'update') + $afdBase + @('--origin-name', $origin,
            '--enabled-state', 'Disabled', '--only-show-errors', '--output', 'none')) | Out-Null
    }
}
foreach ($target in @('aro', 'onprem')) {
    $settings = Get-TargetSettings $config $target
    Invoke-Tool rad @('app', 'delete', 'shop', '--group', 'default', '--workspace',
        $settings.Workspace, '--yes') | Out-Null
    $resources = @(
        'route/shop', 'component/statestore', 'component/secretstore',
        'secret/shop-db-credentials', 'secret/shop-redis-password', 'secret/shop-db-seed-credentials',
        'pod/shop-db-seed', 'serviceaccount/shop-api', 'rolebinding/shop-api-database-secret-reader',
        'role/shop-api-database-secret-reader', 'rolebinding/chaos-operator',
        'rolebinding/chaos-operator-readonly', 'role/chaos-operator', 'role/chaos-operator-readonly',
        'serviceaccount/chaos-operator'
    )
    Invoke-Tool kubectl (@('--context', $settings.Context, '--namespace', 'shop', 'delete') +
        $resources + @('--ignore-not-found', '--wait=false')) | Out-Null
}
Invoke-Tool kubectl @('--context', $config.ARO_CONTEXT, '--namespace', 'shop', 'delete',
    'networkpolicy/demo-outage', '--ignore-not-found', '--wait=false') | Out-Null
$secrets = Invoke-Tool az @('keyvault', 'secret', 'list', '--vault-name', $config.KEY_VAULT_NAME,
    '--query', '[].name', '--output', 'json', '--only-show-errors') | ConvertFrom-Json
foreach ($name in @('shop-db-password', 'shop-redis-password')) {
    if ($name -in $secrets) {
        Invoke-Tool az @('keyvault', 'secret', 'delete', '--vault-name', $config.KEY_VAULT_NAME,
            '--name', $name, '--only-show-errors', '--output', 'none') | Out-Null
    }
}
Write-Host 'Demo applications and app resources removed. ARO, Radius, Dapr, and CloudNativePG remain installed.'

#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'AZURE_LOCATION', 'KEY_VAULT_NAME',
    'FRONT_DOOR_PROFILE_NAME', 'ARO_SERVICE_PRINCIPAL_CLIENT_ID',
    'ARO_SERVICE_PRINCIPAL_CLIENT_SECRET', 'ARO_SERVICE_PRINCIPAL_OBJECT_ID')
Select-ShopSubscription $config
foreach ($provider in @('Microsoft.Authorization', 'Microsoft.Cache', 'Microsoft.Cdn',
    'Microsoft.Compute', 'Microsoft.DBforPostgreSQL', 'Microsoft.KeyVault',
    'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.OperationalInsights',
    'Microsoft.RedHatOpenShift', 'Microsoft.Storage')) {
    Invoke-Tool az @('provider', 'register', '--namespace', $provider, '--wait',
        '--only-show-errors', '--output', 'none') | Out-Null
}
Invoke-Tool az @('group', 'create', '--name', $config.AZURE_RESOURCE_GROUP, '--location',
    $config.AZURE_LOCATION, '--only-show-errors', '--output', 'none') | Out-Null
if (-not $config.OPENSHIFT_VERSION) {
    $versions = Invoke-Tool az @('aro', 'get-versions', '--location',
        $config.AZURE_LOCATION, '--output', 'json') | ConvertFrom-Json
    $config.OPENSHIFT_VERSION = $versions | Sort-Object { [version]$_ } | Select-Object -Last 1
}
Require-Values $config @('OPENSHIFT_VERSION')
$pullSecret = if ($config.RED_HAT_PULL_SECRET_FILE) {
    Get-Content -LiteralPath $config.RED_HAT_PULL_SECRET_FILE -Raw
} else { '' }
$parameters = @{
    location = $config.AZURE_LOCATION; openShiftVersion = $config.OPENSHIFT_VERSION
    keyVaultName = $config.KEY_VAULT_NAME; frontDoorProfileName = $config.FRONT_DOOR_PROFILE_NAME
    aroServicePrincipalClientId = $config.ARO_SERVICE_PRINCIPAL_CLIENT_ID
    aroServicePrincipalClientSecret = $config.ARO_SERVICE_PRINCIPAL_CLIENT_SECRET
    aroServicePrincipalObjectId = $config.ARO_SERVICE_PRINCIPAL_OBJECT_ID
    redHatPullSecret = $pullSecret
    aroClusterName = $config.ARO_CLUSTER_NAME; onpremClusterName = $config.ONPREM_CLUSTER_NAME
}
$parametersFile = Join-Path $script:SecretsDir "infra-parameters-$([guid]::NewGuid()).json"
try {
    Write-ParametersFile $parametersFile $parameters
    Invoke-Tool az @('deployment', 'group', 'create', '--subscription', $config.AZURE_SUBSCRIPTION_ID,
        '--resource-group', $config.AZURE_RESOURCE_GROUP, '--name', 'adaptive-shop-infrastructure',
        '--template-file', (Join-Path $script:RepoRoot 'infra/azure/main.bicep'),
        '--parameters', "@$parametersFile", '--only-show-errors', '--output', 'none') | Out-Null
} finally {
    if (Test-Path -LiteralPath $parametersFile) { Remove-Item -LiteralPath $parametersFile }
}
Write-Host "Infrastructure deployed with ARO $($config.OPENSHIFT_VERSION) in $($config.AZURE_LOCATION)."

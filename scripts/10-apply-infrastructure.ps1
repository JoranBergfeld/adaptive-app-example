#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
. "$PSScriptRoot/lib/capacity.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'AZURE_LOCATION', 'KEY_VAULT_NAME',
    'FRONT_DOOR_PROFILE_NAME', 'ARO_SERVICE_PRINCIPAL_CLIENT_ID',
    'ARO_SERVICE_PRINCIPAL_CLIENT_SECRET', 'ARO_SERVICE_PRINCIPAL_OBJECT_ID',
    'ONPREM_SERVICE_PRINCIPAL_CLIENT_ID', 'ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET',
    'ONPREM_SERVICE_PRINCIPAL_OBJECT_ID')
if ($config.ARO_SERVICE_PRINCIPAL_CLIENT_ID -eq $config.ONPREM_SERVICE_PRINCIPAL_CLIENT_ID -or
    $config.ARO_SERVICE_PRINCIPAL_OBJECT_ID -eq $config.ONPREM_SERVICE_PRINCIPAL_OBJECT_ID) {
    throw 'ARO requires a unique service principal per cluster. Configure separate ONPREM_SERVICE_PRINCIPAL_* credentials using script 05 -Target onprem.'
}
Select-ShopSubscription $config
Test-ShopCapacity $config
foreach ($provider in @('Microsoft.Authorization', 'Microsoft.Cache', 'Microsoft.Cdn',
    'Microsoft.Compute', 'Microsoft.DBforPostgreSQL', 'Microsoft.KeyVault',
    'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.OperationalInsights',
    'Microsoft.RedHatOpenShift', 'Microsoft.Storage')) {
    Invoke-Tool az @('provider', 'register', '--namespace', $provider, '--wait',
        '--only-show-errors', '--output', 'none') | Out-Null
}
$providerObjectId = Invoke-Tool az @('ad', 'sp', 'show', '--id',
    'f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875', '--query', 'id', '--output', 'tsv',
    '--only-show-errors')
if ([string]::IsNullOrWhiteSpace($providerObjectId)) {
    throw 'Could not resolve the Azure Red Hat OpenShift resource provider service principal object ID.'
}
Invoke-Tool az @('group', 'create', '--name', $config.AZURE_RESOURCE_GROUP, '--location',
    $config.AZURE_LOCATION, '--only-show-errors', '--output', 'none') | Out-Null
if (-not $config.OPENSHIFT_VERSION) {
    $versions = Invoke-Tool az @('aro', 'get-versions', '--location',
        $config.AZURE_LOCATION, '--output', 'json') | ConvertFrom-Json
    $config.OPENSHIFT_VERSION = $versions | Sort-Object { [version]$_ } | Select-Object -Last 1
}
Require-Values $config @('OPENSHIFT_VERSION')
if (($config.ARO_MASTER_VM_SIZE -match '_v6$' -or $config.ARO_WORKER_VM_SIZE -match '_v6$') -and
    [version]$config.OPENSHIFT_VERSION -lt [version]'4.19.0') {
    throw 'Dsv6 node sizes require OpenShift 4.19 or later. Update OPENSHIFT_VERSION or leave it blank.'
}
$pullSecret = if ($config.RED_HAT_PULL_SECRET_FILE) {
    Get-Content -LiteralPath $config.RED_HAT_PULL_SECRET_FILE -Raw
} else { '' }
$parameters = @{
    location = $config.AZURE_LOCATION; openShiftVersion = $config.OPENSHIFT_VERSION
    keyVaultName = $config.KEY_VAULT_NAME; frontDoorProfileName = $config.FRONT_DOOR_PROFILE_NAME
    frontDoorEndpointName = $config.FRONT_DOOR_ENDPOINT_NAME
    aroMasterVmSize = $config.ARO_MASTER_VM_SIZE; aroWorkerVmSize = $config.ARO_WORKER_VM_SIZE
    aroServicePrincipalClientId = $config.ARO_SERVICE_PRINCIPAL_CLIENT_ID
    aroServicePrincipalClientSecret = $config.ARO_SERVICE_PRINCIPAL_CLIENT_SECRET
    aroServicePrincipalObjectId = $config.ARO_SERVICE_PRINCIPAL_OBJECT_ID
    onpremServicePrincipalClientId = $config.ONPREM_SERVICE_PRINCIPAL_CLIENT_ID
    onpremServicePrincipalClientSecret = $config.ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET
    onpremServicePrincipalObjectId = $config.ONPREM_SERVICE_PRINCIPAL_OBJECT_ID
    aroResourceProviderObjectId = $providerObjectId.Trim()
    redHatPullSecret = $pullSecret
    aroClusterName = $config.ARO_CLUSTER_NAME; onpremClusterName = $config.ONPREM_CLUSTER_NAME
}
$networkRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'
foreach ($target in @(
    @{ Cluster = $config.ARO_CLUSTER_NAME; Parameter = 'aroProviderNetworkRoleName' },
    @{ Cluster = $config.ONPREM_CLUSTER_NAME; Parameter = 'onpremProviderNetworkRoleName' }
)) {
    $scope = "/subscriptions/$($config.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($config.AZURE_RESOURCE_GROUP)/providers/Microsoft.Network/virtualNetworks/$($target.Cluster)-vnet"
    $roles = Invoke-Tool az @('role', 'assignment', 'list', '--subscription',
        $config.AZURE_SUBSCRIPTION_ID, '--scope', $scope, '--output', 'json',
        '--only-show-errors') | ConvertFrom-Json
    $matches = @($roles | Where-Object {
        $_.scope -eq $scope -and $_.principalId -eq $providerObjectId.Trim() -and
        ($_.roleDefinitionId -split '/')[-1] -eq $networkRoleId
    })
    if ($matches.Count -gt 1) {
        throw "Multiple provider Network Contributor assignments found at $scope. Resolve the ambiguity before deployment."
    }
    if ($matches.Count -eq 1) {
        if ([string]::IsNullOrWhiteSpace($matches[0].name)) {
            throw "Existing provider Network Contributor assignment at $scope has no name."
        }
        $parameters[$target.Parameter] = $matches[0].name
        Write-Host "Reusing provider Network Contributor assignment $($matches[0].name) on $($target.Cluster)-vnet."
    }
}
$parametersFile = Join-Path $script:SecretsDir "infra-parameters-$([guid]::NewGuid()).json"
try {
    Write-ParametersFile $parametersFile $parameters
    Invoke-Tool az @('deployment', 'group', 'validate', '--subscription', $config.AZURE_SUBSCRIPTION_ID,
        '--resource-group', $config.AZURE_RESOURCE_GROUP, '--name', 'adaptive-shop-infrastructure',
        '--template-file', (Join-Path $script:RepoRoot 'infra/azure/main.bicep'),
        '--parameters', "@$parametersFile", '--validation-level', 'Provider',
        '--only-show-errors', '--output', 'none') | Out-Null
    Invoke-Tool az @('deployment', 'group', 'create', '--subscription', $config.AZURE_SUBSCRIPTION_ID,
        '--resource-group', $config.AZURE_RESOURCE_GROUP, '--name', 'adaptive-shop-infrastructure',
        '--template-file', (Join-Path $script:RepoRoot 'infra/azure/main.bicep'),
        '--parameters', "@$parametersFile", '--only-show-errors', '--output', 'none') | Out-Null
} finally {
    if (Test-Path -LiteralPath $parametersFile) { Remove-Item -LiteralPath $parametersFile }
}
Write-Host "Infrastructure deployed with ARO $($config.OPENSHIFT_VERSION) in $($config.AZURE_LOCATION)."

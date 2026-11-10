#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'ARO_SERVICE_PRINCIPAL_CLIENT_ID',
    'ARO_SERVICE_PRINCIPAL_CLIENT_SECRET', 'RECIPE_REF')
Select-ShopSubscription $config
if (-not $config.AZURE_TENANT_ID) {
    $config.AZURE_TENANT_ID = Invoke-Tool az @('account', 'show', '--query', 'tenantId', '--output', 'tsv')
}
$branch = Invoke-Tool git @('-C', $script:RepoRoot, 'ls-remote', '--exit-code', 'origin',
    "refs/heads/$($config.RECIPE_REF)") -AllowFailure
if ($branch.ExitCode -ne 0) {
    $tag = Invoke-Tool git @('-C', $script:RepoRoot, 'ls-remote', '--exit-code', 'origin',
        "refs/tags/$($config.RECIPE_REF)") -AllowFailure
    if ($tag.ExitCode -ne 0) { throw 'RECIPE_REF is not available on the GitHub remote.' }
}
Invoke-Tool rad @('credential', 'register', 'azure', 'sp', '--client-id',
    $config.ARO_SERVICE_PRINCIPAL_CLIENT_ID, '--client-secret', $config.ARO_SERVICE_PRINCIPAL_CLIENT_SECRET,
    '--tenant-id', $config.AZURE_TENANT_ID, '--workspace', 'aro-workspace') | Out-Null
Invoke-Tool rad @('deploy', (Join-Path $script:RepoRoot 'radius/recipe-packs/aro.bicep'),
    '--workspace', 'aro-workspace', '--group', 'default') | Out-Null
Invoke-Tool rad @('deploy', (Join-Path $script:RepoRoot 'radius/environments/aro.bicep'),
    '--workspace', 'aro-workspace', '--group', 'default', '--parameters',
    "azureSubscriptionId=$($config.AZURE_SUBSCRIPTION_ID)", '--parameters',
    "azureResourceGroupName=$($config.AZURE_RESOURCE_GROUP)") | Out-Null
Invoke-Tool rad @('deploy', (Join-Path $script:RepoRoot 'radius/recipe-packs/onprem.bicep'),
    '--workspace', 'onprem-workspace', '--group', 'default', '--parameters',
    "recipeRef=$($config.RECIPE_REF)") | Out-Null
Invoke-Tool rad @('deploy', (Join-Path $script:RepoRoot 'radius/environments/onprem.bicep'),
    '--workspace', 'onprem-workspace', '--group', 'default') | Out-Null
Write-Host 'Radius environments configured with separate recipes and the same app definition.'

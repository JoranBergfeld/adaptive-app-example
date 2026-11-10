#requires -Version 7.3
param([Parameter(Mandatory)][ValidateSet('aro', 'onprem')][string]$Target)
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP', 'KEY_VAULT_NAME', 'FRONT_DOOR_PROFILE_NAME')
Select-ShopSubscription $config
Initialize-DatabasePassword $config
$settings = Get-TargetSettings $config $Target
$context = $settings.Context
$passwordFile = Join-Path $script:SecretsDir 'database-password'
$parametersFile = Join-Path $script:SecretsDir "deploy-parameters-$([guid]::NewGuid()).json"
$patchFile = Join-Path $script:SecretsDir "deployment-patch-$([guid]::NewGuid()).json"
$kubectlBase = @('--context', $context, '--namespace', 'shop')

function New-DatabaseSecret {
    param([string]$Name)
    $manifest = Invoke-Tool kubectl ($kubectlBase + @('create', 'secret', 'generic', $Name,
        '--from-literal=username=shopadmin', "--from-file=password=$passwordFile",
        '--dry-run=client', '--output', 'yaml'))
    Apply-ShopManifest $context $manifest
}

function Deploy-ShopApplication {
    param([bool]$Workload)
    Write-ParametersFile $parametersFile @{
        imageRegistry = $config.IMAGE_REGISTRY; imageTag = $config.IMAGE_TAG
        databasePassword = $config.DATABASE_PASSWORD; deployWorkload = $Workload
    }
    Invoke-Tool rad @('deploy', (Join-Path $script:RepoRoot 'radius/app.bicep'),
        '--workspace', $settings.Workspace, '--group', 'default', '--environment', $Target,
        '--parameters', "@$parametersFile") | Out-Null
}

try {
    if ($Target -eq 'aro') {
        Invoke-Tool az @('keyvault', 'secret', 'set', '--vault-name', $config.KEY_VAULT_NAME,
            '--name', 'shop-db-password', '--file', $passwordFile,
            '--only-show-errors', '--output', 'none') | Out-Null
    } else {
        Invoke-Tool kubectl @('--context', $context, 'apply', '--filename',
            (Join-Path $script:RepoRoot 'infra/onprem-style/secret-rbac.yaml')) | Out-Null
        New-DatabaseSecret 'shop-db-credentials'
    }
    Deploy-ShopApplication $false
    $databaseHost = Get-ResourceProperty $settings.Workspace 'Radius.Data/postgreSqlDatabases' 'shop-postgresql' 'host'
    $redisHost = Get-ResourceProperty $settings.Workspace 'Radius.Data/redisCaches' 'shop-cache' 'host'
    $redisPort = Get-ResourceProperty $settings.Workspace 'Radius.Data/redisCaches' 'shop-cache' 'port'
    if ($Target -eq 'onprem') {
        Invoke-Tool kubectl ($kubectlBase + @('wait', '--for=condition=Ready',
            'clusters.postgresql.cnpg.io/shop-postgresql', '--timeout=10m')) | Out-Null
        Invoke-Tool kubectl ($kubectlBase + @('wait', '--for=condition=Available',
            'deployment/shop-cache', '--timeout=5m')) | Out-Null
        $databaseHost = 'shop-postgresql-rw.shop.svc.cluster.local'
    }

    New-DatabaseSecret 'shop-db-seed-credentials'
    $seed = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'infra/azure/postgres-seed-pod.yaml') -Raw
    Apply-ShopManifest $context ($seed.Replace('__DATABASE_HOST__', $databaseHost).Replace('__DATABASE_PORT__', '5432'))
    Invoke-Tool kubectl ($kubectlBase + @('wait', '--for=condition=Ready', 'pod/shop-db-seed',
        '--timeout=5m')) | Out-Null
    $waitForPostgres = 'attempt=0; until pg_isready --quiet; do attempt=$((attempt + 1)); if [ "$attempt" -ge 120 ]; then exit 1; fi; sleep 5; done'
    Invoke-Tool kubectl ($kubectlBase + @('exec', 'pod/shop-db-seed', '--', 'sh', '-c', $waitForPostgres)) | Out-Null
    $sql = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'app/api/init.sql') -Raw
    Invoke-Tool kubectl ($kubectlBase + @('exec', '--stdin', 'pod/shop-db-seed', '--',
        'psql', '--set', 'ON_ERROR_STOP=1')) -InputText $sql | Out-Null
    Invoke-Tool kubectl ($kubectlBase + @('delete', 'pod/shop-db-seed',
        'secret/shop-db-seed-credentials', '--ignore-not-found')) | Out-Null

    if ($Target -eq 'aro') {
        $redisName = $redisHost.Split('.')[0]
        $redisPassword = Invoke-Tool az @('redisenterprise', 'database', 'list-keys',
            '--resource-group', $config.AZURE_RESOURCE_GROUP, '--cluster-name', $redisName,
            '--database-name', 'default', '--query', 'primaryKey', '--output', 'tsv', '--only-show-errors')
        if (-not $redisPassword) { throw 'Azure Managed Redis did not return a primary access key.' }
        $redisPasswordFile = Join-Path $script:SecretsDir 'redis-password'
        Write-PrivateText $redisPasswordFile $redisPassword
        Invoke-Tool az @('keyvault', 'secret', 'set', '--vault-name', $config.KEY_VAULT_NAME,
            '--name', 'shop-redis-password', '--file', $redisPasswordFile,
            '--only-show-errors', '--output', 'none') | Out-Null
        $serviceAccount = Invoke-Tool kubectl ($kubectlBase + @('create', 'serviceaccount',
            'shop-api', '--dry-run=client', '--output', 'yaml'))
        Apply-ShopManifest $context $serviceAccount
        if (-not $config.APP_IDENTITY_CLIENT_ID) {
            $config.APP_IDENTITY_CLIENT_ID = Invoke-Tool az @('deployment', 'group', 'show',
                '--resource-group', $config.AZURE_RESOURCE_GROUP, '--name', 'adaptive-shop-infrastructure',
                '--query', 'properties.outputs.appIdentityClientId.value', '--output', 'tsv')
        }
        Require-Values $config @('APP_IDENTITY_CLIENT_ID')
        $secretStore = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'dapr/components/aro/secretstore.yaml') -Raw
        Apply-ShopManifest $context ($secretStore.Replace('__KEY_VAULT_NAME__', $config.KEY_VAULT_NAME).
            Replace('__IDENTITY_CLIENT_ID__', $config.APP_IDENTITY_CLIENT_ID))
        Invoke-Tool kubectl ($kubectlBase + @('annotate', 'serviceaccount', 'shop-api',
            "azure.workload.identity/client-id=$($config.APP_IDENTITY_CLIENT_ID)", '--overwrite')) | Out-Null
    }
    $stateStore = Get-Content -LiteralPath (Join-Path $script:RepoRoot "dapr/components/$Target/statestore.yaml") -Raw
    Apply-ShopManifest $context ($stateStore.Replace('__REDIS_HOST__', "${redisHost}:$redisPort"))
    Deploy-ShopApplication $true
    $template = @{ spec = @{ serviceAccountName = 'shop-api' } }
    if ($Target -eq 'aro') {
        $template.metadata = @{ labels = @{ 'azure.workload.identity/use' = 'true' } }
    }
    Write-PrivateText $patchFile (@{ spec = @{ template = $template } } | ConvertTo-Json -Depth 10)
    Invoke-Tool kubectl ($kubectlBase + @('patch', 'deployment', 'shop-api', '--type', 'merge',
        '--patch-file', $patchFile)) | Out-Null
    foreach ($deployment in @('shop-api', 'shop-web')) {
        Invoke-Tool kubectl ($kubectlBase + @('rollout', 'status', "deployment/$deployment", '--timeout=10m')) | Out-Null
    }
    $consoleUrl = Invoke-Tool az @('aro', 'show', '--resource-group', $config.AZURE_RESOURCE_GROUP,
        '--name', $settings.Cluster, '--query', 'consoleUrl', '--output', 'tsv', '--only-show-errors')
    if ($consoleUrl -notmatch '^https://console-openshift-console\.([^/]+)') {
        throw 'Could not derive the ARO application domain from consoleUrl.'
    }
    $shopHost = "shop.$($Matches[1])"
    $route = Invoke-Tool oc @('--context', $context, '--namespace', 'shop', 'create', 'route',
        'edge', 'shop', '--service=shop-web-web', "--hostname=$shopHost", '--insecure-policy=Redirect',
        '--dry-run=client', '--output', 'yaml')
    Apply-ShopManifest $context $route
    Wait-ShopReady "https://$shopHost/readyz"
    Set-FrontDoorOrigin $config $Target $shopHost
    $frontDoorHost = Invoke-Tool az @('afd', 'endpoint', 'show', '--resource-group',
        $config.AZURE_RESOURCE_GROUP, '--profile-name', $config.FRONT_DOOR_PROFILE_NAME,
        '--endpoint-name', 'shop', '--query', 'hostName', '--output', 'tsv', '--only-show-errors')
    Write-Host "Deployment ready on ${Target}: https://$shopHost"
    Write-Host "Front Door endpoint (switch traffic explicitly): https://$frontDoorHost"
} finally {
    foreach ($path in @($parametersFile, $patchFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    $cleanup = Invoke-Tool kubectl ($kubectlBase + @('delete', 'pod/shop-db-seed',
        'secret/shop-db-seed-credentials', '--ignore-not-found', '--wait=false')) -AllowFailure
    if ($cleanup.ExitCode -ne 0) { Write-Warning 'Could not remove temporary database seed resources.' }
}

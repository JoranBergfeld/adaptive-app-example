#requires -Version 7.3
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:SecretsDir = Join-Path $script:RepoRoot '.secrets'

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [string]$InputText,
        [switch]$AllowFailure
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $output = $InputText | & $Name @Arguments
    } else {
        $output = & $Name @Arguments
    }
    $code = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine)
    if ($AllowFailure) {
        return @{ ExitCode = $code; Output = $text }
    }
    if ($code -ne 0) {
        # Do not echo arguments: several commands carry credentials.
        throw "$Name failed with exit code $code. See the command's error output."
    }
    return $text
}

function Protect-PrivatePath {
    param([string]$Path)
    if ($IsWindows) {
        $isDirectory = Test-Path -LiteralPath $Path -PathType Container
        # A fresh descriptor modifies only the DACL, not the owner or audit SACL.
        $acl = if ($isDirectory) {
            [Security.AccessControl.DirectorySecurity]::new()
        } else {
            [Security.AccessControl.FileSecurity]::new()
        }
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $inheritance = if ($isDirectory) {
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else {
            [Security.AccessControl.InheritanceFlags]::None
        }
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($rule)
        if ($isDirectory) {
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl)
        } else {
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl)
        }
    } else {
        $mode = if (Test-Path -LiteralPath $Path -PathType Container) {
            [IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
        } else {
            [IO.UnixFileMode]'UserRead, UserWrite'
        }
        [IO.File]::SetUnixFileMode($Path, $mode)
    }
}

function Initialize-SecretsDirectory {
    [void][IO.Directory]::CreateDirectory($script:SecretsDir)
    Protect-PrivatePath $script:SecretsDir
}

function Write-PrivateText {
    param([string]$Path, [string]$Text)
    Initialize-SecretsDirectory
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.File]::WriteAllText($Path, '')
    }
    Protect-PrivatePath $Path
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-ShopConfig {
    $defaults = @{
        AZURE_SUBSCRIPTION_ID = ''; AZURE_RESOURCE_GROUP = ''; AZURE_LOCATION = ''
        KEY_VAULT_NAME = ''; FRONT_DOOR_PROFILE_NAME = ''; AZURE_TENANT_ID = ''
        FRONT_DOOR_ENDPOINT_NAME = 'shop'
        ARO_MASTER_VM_SIZE = 'Standard_D8s_v5'; ARO_WORKER_VM_SIZE = 'Standard_D4s_v5'
        ARO_SERVICE_PRINCIPAL_CLIENT_ID = ''; ARO_SERVICE_PRINCIPAL_CLIENT_SECRET = ''
        ARO_SERVICE_PRINCIPAL_OBJECT_ID = ''; RED_HAT_PULL_SECRET_FILE = ''
        ONPREM_SERVICE_PRINCIPAL_CLIENT_ID = ''; ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET = ''
        ONPREM_SERVICE_PRINCIPAL_OBJECT_ID = ''
        ARO_CLUSTER_NAME = 'adaptive-aro'; ONPREM_CLUSTER_NAME = 'adaptive-onprem'
        ARO_CONTEXT = 'aro-demo'; ONPREM_CONTEXT = 'onprem-demo'
        RECIPE_REF = 'main'; GITHUB_REPOSITORY = 'JoranBergfeld/adaptive-app-example'
        RADIUS_VERSION = '0.60.2'; DAPR_VERSION = '1.19.0'; CNPG_VERSION = '1.30.1'
        IMAGE_REGISTRY = ''; IMAGE_TAG = ''; DATABASE_PASSWORD = ''; OPENSHIFT_VERSION = ''
        APP_IDENTITY_CLIENT_ID = ''; KUBECONFIG = ''
    }
    $config = @{}
    foreach ($key in $defaults.Keys) {
        $config[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    $envFile = Join-Path $script:RepoRoot '.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in [IO.File]::ReadAllLines($envFile)) {
            if ($line -match '^\s*(#.*)?$') { continue }
            if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                throw 'Invalid .env entry. Use NAME=value, with optional surrounding quotes.'
            }
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value.StartsWith('"') -or $value.StartsWith("'")) {
                if ($value.Length -lt 2 -or $value[-1] -ne $value[0]) {
                    throw "Unmatched quotes for $key in .env."
                }
                $value = $value.Substring(1, $value.Length - 2)
            }
            $config[$key] = $value
        }
    }
    foreach ($key in $defaults.Keys) {
        if ([string]::IsNullOrWhiteSpace($config[$key])) { $config[$key] = $defaults[$key] }
    }
    $config.FromCredentialsFile = $false
    $config.OnpremFromCredentialsFile = $false
    foreach ($target in @('aro', 'onprem')) {
        $prefix = $target.ToUpperInvariant()
        $fileName = if ($target -eq 'aro') { 'service-principal.json' } else { 'onprem-service-principal.json' }
        $credentialsFile = Join-Path $script:SecretsDir $fileName
        if ((Test-Path -LiteralPath $credentialsFile) -and
            -not ($config["${prefix}_SERVICE_PRINCIPAL_CLIENT_ID"] -or
                  $config["${prefix}_SERVICE_PRINCIPAL_CLIENT_SECRET"] -or
                  $config["${prefix}_SERVICE_PRINCIPAL_OBJECT_ID"])) {
            $credentials = Get-SavedPrincipal -Target $target
            $config["${prefix}_SERVICE_PRINCIPAL_CLIENT_ID"] = $credentials.appId
            $config["${prefix}_SERVICE_PRINCIPAL_CLIENT_SECRET"] = $credentials.password
            $config["${prefix}_SERVICE_PRINCIPAL_OBJECT_ID"] = $credentials['objectId']
            if (-not $config.AZURE_TENANT_ID) { $config.AZURE_TENANT_ID = $credentials.tenant }
            $flag = if ($target -eq 'aro') { 'FromCredentialsFile' } else { 'OnpremFromCredentialsFile' }
            $config[$flag] = $true
        }
    }
    if (-not $config.IMAGE_REGISTRY) {
        $config.IMAGE_REGISTRY = "ghcr.io/$($config.GITHUB_REPOSITORY.ToLowerInvariant())"
    }
    if (-not $config.IMAGE_TAG) {
        $config.IMAGE_TAG = Invoke-Tool git @('-C', $script:RepoRoot, 'rev-parse', 'HEAD')
    }
    if (-not $config.KUBECONFIG) {
        $config.KUBECONFIG = @(
            (Join-Path $script:SecretsDir 'aro-demo.kubeconfig'),
            (Join-Path $script:SecretsDir 'onprem-demo.kubeconfig')
        ) -join [IO.Path]::PathSeparator
    }
    $env:KUBECONFIG = $config.KUBECONFIG
    return $config
}

function Get-SavedPrincipal {
    param([ValidateSet('aro', 'onprem')][string]$Target = 'aro')
    $fileName = if ($Target -eq 'aro') { 'service-principal.json' } else { 'onprem-service-principal.json' }
    $path = Join-Path $script:SecretsDir $fileName
    $credentials = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('appId', 'password', 'tenant')) {
        if ($credentials[$key] -isnot [string] -or -not $credentials[$key]) {
            throw "Invalid saved service principal credentials: missing $key."
        }
    }
    if ($credentials['objectId'] -and $credentials['objectId'] -isnot [string]) {
        throw 'Invalid saved service principal object ID.'
    }
    return $credentials
}

function Require-Values {
    param([hashtable]$Config, [string[]]$Names)
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($Config[$name])) {
            throw "Set $name in .env or the environment before continuing."
        }
    }
}

function Select-ShopSubscription {
    param([hashtable]$Config)
    if (-not $Config.AZURE_SUBSCRIPTION_ID) {
        $Config.AZURE_SUBSCRIPTION_ID = Invoke-Tool az @('account', 'show', '--query', 'id', '--output', 'tsv')
    }
    Require-Values $Config @('AZURE_SUBSCRIPTION_ID')
    Invoke-Tool az @('account', 'set', '--subscription', $Config.AZURE_SUBSCRIPTION_ID) | Out-Null
}

function Get-TargetSettings {
    param([hashtable]$Config, [ValidateSet('aro', 'onprem')][string]$Target)
    return @{
        Context = $(if ($Target -eq 'aro') { $Config.ARO_CONTEXT } else { $Config.ONPREM_CONTEXT })
        Cluster = $(if ($Target -eq 'aro') { $Config.ARO_CLUSTER_NAME } else { $Config.ONPREM_CLUSTER_NAME })
        Workspace = "$Target-workspace"
    }
}

function Initialize-DatabasePassword {
    param([hashtable]$Config)
    $path = Join-Path $script:SecretsDir 'database-password'
    if (-not $Config.DATABASE_PASSWORD) {
        $Config.DATABASE_PASSWORD = if (Test-Path -LiteralPath $path) {
            [IO.File]::ReadAllText($path)
        } else {
            [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        }
    }
    Require-Values $Config @('DATABASE_PASSWORD')
    Write-PrivateText $path $Config.DATABASE_PASSWORD
}

function Write-ParametersFile {
    param([string]$Path, [hashtable]$Values)
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    $document = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    }
    Write-PrivateText $Path ($document | ConvertTo-Json -Depth 20)
}

function Get-ResourceProperty {
    param([string]$Workspace, [string]$Type, [string]$Name, [string]$Property)
    $resource = Invoke-Tool rad @('resource', 'show', $Type, $Name, '--workspace', $Workspace,
        '--group', 'default', '--application', 'shop', '--output', 'json') |
        ConvertFrom-Json -AsHashtable
    $value = $resource.properties[$Property]
    if ($null -eq $value -or "$value" -eq '') { throw "Resource $Name has no $Property output." }
    return $value
}

function Apply-ShopManifest {
    param([string]$Context, [string]$Text)
    Invoke-Tool kubectl @('--context', $Context, 'apply', '--namespace', 'shop', '--filename', '-') `
        -InputText $Text | Out-Null
}

function Wait-ShopReady {
    param([string]$Uri, [int]$Attempts = 60, [int]$DelaySeconds = 5)
    $reason = 'No response'
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 10 -SkipHttpErrorCheck
            if ($response.StatusCode -eq 200) { return }
            $reason = "HTTP $($response.StatusCode)"
        } catch [System.Net.Http.HttpRequestException] {
            $reason = $_.Exception.Message
        } catch [System.Threading.Tasks.TaskCanceledException] {
            $reason = $_.Exception.Message
        }
        if ($attempt + 1 -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Readiness check failed at ${Uri}: $reason"
}

function Set-FrontDoorOrigin {
    param([hashtable]$Config, [string]$Target, [string]$OriginHost)
    $base = @('--resource-group', $Config.AZURE_RESOURCE_GROUP, '--profile-name',
        $Config.FRONT_DOOR_PROFILE_NAME, '--origin-group-name', 'shop-origins')
    $origins = Invoke-Tool az (@('afd', 'origin', 'list') + $base +
        @('--query', '[].name', '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
    $operation = if ($Target -in $origins) { 'update' } else { 'create' }
    $arguments = @('afd', 'origin', $operation) + $base + @('--origin-name', $Target,
        '--host-name', $OriginHost, '--origin-host-header', $OriginHost, '--enabled-state',
        'Disabled', '--only-show-errors', '--output', 'none')
    if ($operation -eq 'create') {
        $arguments += @('--http-port', '80', '--https-port', '443', '--priority', '1',
            '--weight', '1000', '--certificate-name-check-enabled', 'true')
    }
    Invoke-Tool az $arguments | Out-Null
}

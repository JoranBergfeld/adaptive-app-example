#requires -Version 7.3
param([ValidateSet('aro', 'onprem')][string]$Target = 'aro')
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP')
Select-ShopSubscription $config
$fileName = if ($Target -eq 'aro') { 'service-principal.json' } else { 'onprem-service-principal.json' }
$credentialsFile = Join-Path $script:SecretsDir $fileName
$prefix = $Target.ToUpperInvariant()
$clientIdKey = "${prefix}_SERVICE_PRINCIPAL_CLIENT_ID"
$secretKey = "${prefix}_SERVICE_PRINCIPAL_CLIENT_SECRET"
$objectIdKey = "${prefix}_SERVICE_PRINCIPAL_OBJECT_ID"
$fromFile = if ($Target -eq 'aro') { $config.FromCredentialsFile } else { $config.OnpremFromCredentialsFile }

if ($config[$clientIdKey] -or $config[$secretKey] -or $config[$objectIdKey]) {
    Require-Values $config @($clientIdKey, $secretKey)
    if ($config[$objectIdKey]) {
        Write-Host "Using the configured $Target service principal; no credentials were changed."
        return
    }
    if (-not $fromFile) {
        Require-Values $config @($objectIdKey)
    }
} else {
    Initialize-SecretsDirectory
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $text = Invoke-Tool az @('ad', 'sp', 'create-for-rbac', '--name',
        "$($config.AZURE_RESOURCE_GROUP)-$Target-$suffix", '--skip-assignment', '--years', '1',
        '--only-show-errors', '--output', 'json')
    # Persist the generated secret before directory lookup so retries can reuse it.
    Write-PrivateText $credentialsFile $text
    $config = Get-ShopConfig
}

$objectId = ''
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $result = Invoke-Tool az @('ad', 'sp', 'show', '--id', $config[$clientIdKey],
        '--query', 'id', '--output', 'tsv', '--only-show-errors') -AllowFailure
    if ($result.ExitCode -eq 0 -and $result.Output) {
        $objectId = $result.Output.Trim()
        break
    }
    if ($attempt -lt 11) { Start-Sleep -Seconds 5 }
}
if (-not $objectId) {
    throw 'Credentials are saved, but directory lookup failed. Check Entra permissions and rerun this script.'
}
$credentials = Get-SavedPrincipal -Target $Target
$credentials.objectId = $objectId
Write-PrivateText $credentialsFile ($credentials | ConvertTo-Json)
Write-Host "Service principal credentials saved privately in .secrets/$fileName."
Write-Host 'Later scripts load them automatically; script 10 assigns the resource-group and vault roles.'

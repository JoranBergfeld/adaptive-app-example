#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP')
Select-ShopSubscription $config
$credentialsFile = Join-Path $script:SecretsDir 'service-principal.json'

if ($config.ARO_SERVICE_PRINCIPAL_CLIENT_ID -or
    $config.ARO_SERVICE_PRINCIPAL_CLIENT_SECRET -or
    $config.ARO_SERVICE_PRINCIPAL_OBJECT_ID) {
    Require-Values $config @('ARO_SERVICE_PRINCIPAL_CLIENT_ID', 'ARO_SERVICE_PRINCIPAL_CLIENT_SECRET')
    if ($config.ARO_SERVICE_PRINCIPAL_OBJECT_ID) {
        Write-Host 'Using the configured service principal; no credentials were changed.'
        return
    }
    if (-not $config.FromCredentialsFile) {
        Require-Values $config @('ARO_SERVICE_PRINCIPAL_OBJECT_ID')
    }
} else {
    Initialize-SecretsDirectory
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $text = Invoke-Tool az @('ad', 'sp', 'create-for-rbac', '--name',
        "$($config.AZURE_RESOURCE_GROUP)-aro-$suffix", '--skip-assignment', '--years', '1',
        '--only-show-errors', '--output', 'json')
    # Persist the generated secret before directory lookup so retries can reuse it.
    Write-PrivateText $credentialsFile $text
    $config = Get-ShopConfig
}

$objectId = ''
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $result = Invoke-Tool az @('ad', 'sp', 'show', '--id', $config.ARO_SERVICE_PRINCIPAL_CLIENT_ID,
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
$credentials = Get-SavedPrincipal
$credentials.objectId = $objectId
Write-PrivateText $credentialsFile ($credentials | ConvertTo-Json)
Write-Host 'Service principal credentials saved privately in .secrets/service-principal.json.'
Write-Host 'Later scripts load them automatically; script 10 assigns the resource-group and vault roles.'

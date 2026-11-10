#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
Require-Values $config @('AZURE_RESOURCE_GROUP')
Select-ShopSubscription $config
Initialize-SecretsDirectory
foreach ($target in @('aro', 'onprem')) {
    $settings = Get-TargetSettings $config $target
    $rawPath = Join-Path $script:SecretsDir "$target.kubeconfig"
    $namedPath = Join-Path $script:SecretsDir "$target-demo.kubeconfig"
    # ARO writes with exclusive-create mode; it has no --overwrite-existing flag.
    $downloadPath = Join-Path $script:SecretsDir "$target-admin-$([guid]::NewGuid()).kubeconfig"
    try {
        Invoke-Tool az @('aro', 'get-admin-kubeconfig', '--resource-group', $config.AZURE_RESOURCE_GROUP,
            '--name', $settings.Cluster, '--file', $downloadPath, '--only-show-errors') | Out-Null
        Protect-PrivatePath $downloadPath
        $kubeconfig = Invoke-Tool kubectl @('--kubeconfig', $downloadPath, 'config', 'view',
            '--minify', '--raw', '--output', 'json') | ConvertFrom-Json -AsHashtable
        $name = "$target-demo"
        $kubeconfig['current-context'] = $name
        $kubeconfig.contexts[0].name = $name
        $kubeconfig.contexts[0].context.cluster = "$name-cluster"
        $kubeconfig.contexts[0].context.user = "$name-user"
        $kubeconfig.clusters[0].name = "$name-cluster"
        $kubeconfig.users[0].name = "$name-user"
        Write-PrivateText $namedPath ($kubeconfig | ConvertTo-Json -Depth 30)
        [IO.File]::Move($downloadPath, $rawPath, $true)
    } finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath }
    }
}
Write-Host 'Private kubeconfigs saved under .secrets/. Contexts: aro-demo and onprem-demo.'

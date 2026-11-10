#requires -Version 7.3
. "$PSScriptRoot/lib/common.ps1"
$config = Get-ShopConfig
if ($config.ARO_CONTEXT -eq $config.ONPREM_CONTEXT) {
    throw 'ARO_CONTEXT and ONPREM_CONTEXT must be different kubeconfig contexts.'
}
Invoke-Tool helm @('repo', 'add', 'dapr', 'https://dapr.github.io/helm-charts/') | Out-Null
Invoke-Tool helm @('repo', 'update', 'dapr') | Out-Null
foreach ($target in @('aro', 'onprem')) {
    $settings = Get-TargetSettings $config $target
    Invoke-Tool kubectl @('--context', $settings.Context, 'cluster-info') | Out-Null
    Invoke-Tool helm @('upgrade', '--install', 'dapr', 'dapr/dapr', '--version',
        $config.DAPR_VERSION, '--namespace', 'dapr-system', '--create-namespace',
        '--kube-context', $settings.Context, '--wait', '--timeout', '15m') | Out-Null
    Invoke-Tool rad @('install', 'kubernetes', '--kubecontext', $settings.Context,
        '--skip-contour-install', '--set', "global.imageTag=$($config.RADIUS_VERSION)",
        '--timeout', '15m') | Out-Null
    $manifest = Invoke-Tool kubectl @('--context', $settings.Context, 'create', 'namespace',
        'shop', '--dry-run=client', '--output', 'yaml')
    Apply-ShopManifest $settings.Context $manifest
    Invoke-Tool kubectl @('--context', $settings.Context, 'apply', '--filename',
        (Join-Path $script:RepoRoot "chaos/rbac-$target.yaml")) | Out-Null
}
$cnpgUrl = "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-$($config.CNPG_VERSION).yaml"
Invoke-Tool kubectl @('--context', $config.ONPREM_CONTEXT, 'apply', '--server-side',
    '--filename', $cnpgUrl) | Out-Null
Invoke-Tool kubectl @('--context', $config.ONPREM_CONTEXT, 'rollout', 'status', '--namespace',
    'cnpg-system', 'deployment/cnpg-controller-manager', '--timeout=10m') | Out-Null
foreach ($target in @('aro', 'onprem')) {
    $settings = Get-TargetSettings $config $target
    Invoke-Tool rad @('workspace', 'create', 'kubernetes', $settings.Workspace,
        '--context', $settings.Context, '--group', 'default', '--force') | Out-Null
    $result = Invoke-Tool rad @('group', 'show', 'default', '--workspace', $settings.Workspace) -AllowFailure
    if ($result.ExitCode -ne 0) {
        Invoke-Tool rad @('group', 'create', 'default', '--workspace', $settings.Workspace) | Out-Null
    }
}
Write-Host 'Dapr, Radius, and CloudNativePG installed. ARO compatibility remains an unverified prerequisite.'

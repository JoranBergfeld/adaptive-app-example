#requires -Version 7.3

function Test-ShopCapacity {
    param([hashtable]$Config)

    $template = Invoke-Tool az @('bicep', 'build', '--file',
        (Join-Path $script:RepoRoot 'infra/azure/main.bicep'), '--stdout') | ConvertFrom-Json
    $clusterNames = @{
        aroClusterName = $Config.ARO_CLUSTER_NAME
        onpremClusterName = $Config.ONPREM_CLUSTER_NAME
    }
    $plans = @($template.resources |
        Where-Object type -eq 'Microsoft.RedHatOpenShift/openShiftClusters' |
        ForEach-Object {
            if ($_.name -notmatch "^\[parameters\('(\w+)'\)\]$" -or
                -not $clusterNames.ContainsKey($Matches[1])) {
                throw 'Capacity preflight cannot resolve the cluster name in main.bicep.'
            }
            @{
                Name = $clusterNames[$Matches[1]]
                Nodes = @(@{ vmSize = $_.properties.masterProfile.vmSize; count = 3 }) +
                    @($_.properties.workerProfiles)
            }
        })
    if ($plans.Count -ne 2) { throw 'Capacity preflight expects two ARO clusters in main.bicep.' }

    $exists = Invoke-Tool az @('group', 'exists', '--subscription', $Config.AZURE_SUBSCRIPTION_ID,
        '--name', $Config.AZURE_RESOURCE_GROUP, '--output', 'tsv', '--only-show-errors')
    if ($exists -notin @('true', 'false')) { throw 'Could not determine whether the resource group exists.' }
    $existing = if ($exists -eq 'true') {
        @(Invoke-Tool az @('aro', 'list', '--subscription', $Config.AZURE_SUBSCRIPTION_ID,
            '--resource-group', $Config.AZURE_RESOURCE_GROUP, '--output', 'json',
            '--only-show-errors') | ConvertFrom-Json)
    } else { @() }
    $nodes = @(
        foreach ($plan in $plans) {
            $cluster = @($existing | Where-Object name -eq $plan.Name)
            if ($cluster.Count -eq 1 -and $cluster[0].provisioningState -eq 'Succeeded') {
                $currentNodes = @(@{ vmSize = $cluster[0].masterProfile.vmSize; count = 3 }) +
                    @($cluster[0].workerProfiles)
                $desired = @($plan.Nodes | ForEach-Object { "$($_.vmSize):$($_.count)" } | Sort-Object)
                $current = @($currentNodes | ForEach-Object { "$($_.vmSize):$($_.count)" } | Sort-Object)
                if (Compare-Object $desired $current) {
                    throw "Existing cluster $($plan.Name) differs from main.bicep; assess topology changes separately."
                }
                continue
            }
            $plan.Nodes
        }
    )
    if (-not $nodes.Count) {
        Write-Host 'Both clusters already exist with the requested topology; no additional node quota required.'
        return
    }
    $sizes = @($nodes.vmSize | Sort-Object -Unique)
    foreach ($size in $sizes) {
        if ($size -notmatch '^[A-Za-z0-9_]+$') {
            throw 'Capacity preflight requires literal VM sizes in main.bicep.'
        }
    }
    $query = '[?' + (($sizes | ForEach-Object { "name=='$_'" }) -join ' || ') + ']'
    $skus = @(Invoke-Tool az @('vm', 'list-skus', '--subscription', $Config.AZURE_SUBSCRIPTION_ID,
        '--location', $Config.AZURE_LOCATION, '--resource-type', 'virtualMachines', '--all',
        '--query', $query, '--output', 'json', '--only-show-errors') | ConvertFrom-Json)
    $required = @{ cores = 0 }
    foreach ($node in $nodes) {
        $matches = @($skus | Where-Object name -eq $node.vmSize)
        if ($matches.Count -ne 1) {
            throw "SKU $($node.vmSize) was not returned for $($Config.AZURE_LOCATION); availability is unknown."
        }
        $sku = $matches[0]
        if (-not $sku.PSObject.Properties['restrictions'] -or $sku.restrictions -isnot [array]) {
            throw "Incomplete restriction metadata for $($node.vmSize); availability is unknown."
        }
        $restrictions = @($sku.restrictions | Where-Object {
            if ($_.type -ne 'Location') { return $false }
            $locations = @(if ($_.PSObject.Properties['restrictionInfo'] -and
                $_.restrictionInfo -and $_.restrictionInfo.PSObject.Properties['locations']) {
                $_.restrictionInfo.locations
            } elseif ($_.PSObject.Properties['values']) {
                $_.values
            })
            -not $locations.Count -or $Config.AZURE_LOCATION -in $locations
        })
        if ($restrictions.Count) {
            $reasons = ($restrictions.reasonCode | Sort-Object -Unique) -join ', '
            throw "SKU $($node.vmSize) is restricted in $($Config.AZURE_LOCATION): $reasons. Request SKU access or explicitly choose another supported size/region."
        }
        $cpus = @($sku.capabilities | Where-Object name -eq 'vCPUs')
        if ($cpus.Count -ne 1 -or $cpus[0].value -notmatch '^[1-9][0-9]*$' -or
            -not $sku.family -or "$($node.count)" -notmatch '^[1-9][0-9]*$') {
            throw "Incomplete CPU/family metadata for $($node.vmSize); capacity is unknown."
        }
        $count = [int]$cpus[0].value * [int]$node.count
        if (-not $required.ContainsKey($sku.family)) { $required[$sku.family] = 0 }
        $required[$sku.family] += $count
        $required.cores += $count
    }
    $usage = @(Invoke-Tool az @('vm', 'list-usage', '--subscription', $Config.AZURE_SUBSCRIPTION_ID,
        '--location', $Config.AZURE_LOCATION, '--output', 'json',
        '--only-show-errors') | ConvertFrom-Json)
    foreach ($name in $required.Keys) {
        $quota = @($usage | Where-Object { $_.name.value -eq $name })
        if ($quota.Count -ne 1 -or "$($quota[0].limit)" -notmatch '^[0-9]+$' -or
            "$($quota[0].currentValue)" -notmatch '^[0-9]+$') {
            throw "Quota $name was not returned with valid values; capacity is unknown."
        }
        $remaining = [int]$quota[0].limit - [int]$quota[0].currentValue
        if ($remaining -lt $required[$name]) {
            throw "Insufficient $name quota in $($Config.AZURE_LOCATION): need $($required[$name]) additional vCPUs, $remaining available. Request more quota or explicitly choose another region."
        }
    }
    Write-Host "Capacity preflight passed in $($Config.AZURE_LOCATION): $($required.cores) additional vCPUs; current SKU restrictions and CPU quotas checked. This is not a capacity reservation or a guarantee of ARO allocation."
}

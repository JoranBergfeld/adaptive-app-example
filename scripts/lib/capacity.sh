#!/usr/bin/env bash

check_capacity() {
  local template plans exists existing sizes query skus requirements usage
  template="$(az bicep build --file "$REPO_ROOT/infra/azure/main.bicep" --stdout)" || return 1
  plans="$(jq -ce --arg aro "$ARO_CLUSTER_NAME" --arg onprem "$ONPREM_CLUSTER_NAME" \
    --arg master "$ARO_MASTER_VM_SIZE" --arg worker "$ARO_WORKER_VM_SIZE" '
    def vm_size:
      if . == "[parameters('\''aroMasterVmSize'\'')]" then $master
      elif . == "[parameters('\''aroWorkerVmSize'\'')]" then $worker else . end;
    [.resources[] | select(.type == "Microsoft.RedHatOpenShift/openShiftClusters") |
      {name: (if .name == "[parameters('\''aroClusterName'\'')]" then $aro
              elif .name == "[parameters('\''onpremClusterName'\'')]" then $onprem
              else error("Capacity preflight cannot resolve the cluster name in main.bicep.") end),
       nodes: ([{vmSize: (.properties.masterProfile.vmSize | vm_size), count: 3}] +
               [.properties.workerProfiles[] | {vmSize: (.vmSize | vm_size), count}])}] |
    if length == 2 then . else error("Capacity preflight expects two ARO clusters.") end
  ' <<<"$template")" || return 1
  exists="$(az group exists --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$AZURE_RESOURCE_GROUP" --output tsv --only-show-errors)" || return 1
  existing='[]'
  case "$exists" in
    true)
      existing="$(az aro list --subscription "$AZURE_SUBSCRIPTION_ID" \
        --resource-group "$AZURE_RESOURCE_GROUP" --output json --only-show-errors)" || return 1
      ;;
    false) ;;
    *) printf 'Could not determine whether the resource group exists.\n' >&2; return 1 ;;
  esac
  plans="$(jq -ce --argjson existing "$existing" '
    [.[] | . as $plan |
      [$existing[] | select(.name == $plan.name and .provisioningState == "Succeeded")] as $found |
      if ($found | length) == 1 then
        ([{vmSize: $found[0].masterProfile.vmSize, count: 3}] +
         [$found[0].workerProfiles[] | {vmSize, count}]) as $current |
        if ($current | sort_by(.vmSize, .count)) == ($plan.nodes | sort_by(.vmSize, .count))
        then empty else error("Existing cluster \($plan.name) differs from main.bicep; assess topology changes separately.") end
      else . end]
  ' <<<"$plans")" || return 1
  if [[ "$plans" == '[]' ]]; then
    printf 'Both clusters already exist with the requested topology; no additional node quota required.\n'
    return
  fi
  sizes="$(jq -ce '[.[].nodes[].vmSize] | unique |
    if all(.[]; type == "string" and test("^[A-Za-z0-9_]+$"))
    then . else error("Capacity preflight requires literal VM sizes in main.bicep.") end
  ' <<<"$plans")" || return 1
  query="$(jq -r '"[?" + (map("name==\u0027" + . + "\u0027") | join(" || ")) + "]"' <<<"$sizes")" || return 1
  skus="$(az vm list-skus --subscription "$AZURE_SUBSCRIPTION_ID" \
    --location "$AZURE_LOCATION" --resource-type virtualMachines --all \
    --query "$query" --output json --only-show-errors)" || return 1
  requirements="$(jq -ce --argjson skus "$skus" --arg region "$AZURE_LOCATION" '
    reduce .[].nodes[] as $node ({cores: 0};
      [$skus[] | select(.name == $node.vmSize)] as $found |
      if ($found | length) != 1 then
        error("SKU \($node.vmSize) was not returned for \($region); availability is unknown.")
      else $found[0] as $sku |
        if ($sku.restrictions | type) != "array" then
          error("Incomplete restriction metadata for \($node.vmSize); availability is unknown.")
        else . end |
        [$sku.restrictions[] | select(.type == "Location") |
          (.restrictionInfo.locations // .values // []) as $locations |
          select(($locations | length) == 0 or
                 any($locations[]; ascii_downcase == ($region | ascii_downcase)))] as $restrictions |
        if ($restrictions | length) > 0 then
          error("SKU \($node.vmSize) is restricted in \($region): \($restrictions | map(.reasonCode) | unique | join(", ")). Request SKU access or explicitly choose another supported size/region.")
        else [$sku.capabilities[] | select(.name == "vCPUs")] as $cpus |
          if ($cpus | length) != 1 or
             (($cpus[0].value | tostring | test("^[1-9][0-9]*$")) | not) or
             ($sku.family | type) != "string" or ($sku.family | length) == 0 or
             (($node.count | tostring | test("^[1-9][0-9]*$")) | not)
          then error("Incomplete CPU/family metadata for \($node.vmSize); capacity is unknown.")
          else (($cpus[0].value | tonumber) * $node.count) as $count |
            .cores += $count | .[$sku.family | ascii_downcase] += $count
          end
        end
      end)
  ' <<<"$plans")" || return 1
  usage="$(az vm list-usage --subscription "$AZURE_SUBSCRIPTION_ID" \
    --location "$AZURE_LOCATION" --output json --only-show-errors)" || return 1
  jq -e --argjson usage "$usage" --arg region "$AZURE_LOCATION" '
    to_entries[] | . as $requirement |
    [$usage[] | select((.name.value | ascii_downcase) == $requirement.key)] as $quota |
    if ($quota | length) != 1 or
       (($quota[0].limit | tostring | test("^[0-9]+$")) | not) or
       (($quota[0].currentValue | tostring | test("^[0-9]+$")) | not)
    then error("Quota \(.key) was not returned with valid values; capacity is unknown.")
    else (($quota[0].limit | tonumber) - ($quota[0].currentValue | tonumber)) as $remaining |
      if $remaining < .value then
        error("Insufficient \(.key) quota in \($region): need \(.value) additional vCPUs, \($remaining) available. Request more quota or explicitly choose another region.")
      else true end
    end
  ' <<<"$requirements" >/dev/null || return 1
  printf 'Capacity preflight passed in %s: %s additional vCPUs; current SKU restrictions and CPU quotas checked. This is not a capacity reservation or a guarantee of ARO allocation.\n' \
    "$AZURE_LOCATION" "$(jq -r .cores <<<"$requirements")"
}

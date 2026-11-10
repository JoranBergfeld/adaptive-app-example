targetScope = 'resourceGroup'

@description('Azure region in which the clusters and supporting resources are created.')
param location string

@description('Latest ARO version returned by `az aro get-versions --location <location>`.')
param openShiftVersion string

@description('Globally unique name for the Azure Key Vault.')
param keyVaultName string

@description('Globally unique name for the Azure Front Door Standard profile.')
param frontDoorProfileName string

@description('Front Door endpoint name. Choose an unused name for a new deployment.')
param frontDoorEndpointName string = 'shop'

@description('Name of the Azure Red Hat OpenShift service principal.')
param aroServicePrincipalClientId string

@secure()
@description('Client secret for the ARO service principal.')
param aroServicePrincipalClientSecret string

@description('Object ID of the ARO service principal.')
param aroServicePrincipalObjectId string

@secure()
@description('Optional Red Hat pull secret. Use an empty string to omit it.')
param redHatPullSecret string = ''

@description('Name of the Azure-hosted ARO cluster.')
param aroClusterName string = 'adaptive-aro'

@description('Name of the on-premises-style ARO stand-in cluster.')
param onpremClusterName string = 'adaptive-onprem'

@description('Master VM size for both clusters. Dsv6 requires OpenShift 4.19 or later.')
param aroMasterVmSize string = 'Standard_D8s_v5'

@description('Worker VM size for both clusters. Dsv6 requires OpenShift 4.19 or later.')
param aroWorkerVmSize string = 'Standard_D4s_v5'

var contributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)
var networkContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4d97b98b-1d4f-4787-a291-c67834d212e7'
)
var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)
var keyVaultSecretsOfficerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

resource aroContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aroServicePrincipalObjectId, contributorRoleId)
  properties: {
    roleDefinitionId: contributorRoleId
    principalId: aroServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource aroVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${aroClusterName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/22'
      ]
    }
    subnets: [
      {
        name: 'master'
        properties: {
          addressPrefix: '10.20.0.0/23'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'worker'
        properties: {
          addressPrefix: '10.20.2.0/23'
        }
      }
    ]
  }
}

resource onpremVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${onpremClusterName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.30.0.0/22'
      ]
    }
    subnets: [
      {
        name: 'master'
        properties: {
          addressPrefix: '10.30.0.0/23'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'worker'
        properties: {
          addressPrefix: '10.30.2.0/23'
        }
      }
    ]
  }
}

resource aroNetworkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aroVnet.id, aroServicePrincipalObjectId, networkContributorRoleId)
  scope: aroVnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: aroServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource onpremNetworkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(onpremVnet.id, aroServicePrincipalObjectId, networkContributorRoleId)
  scope: onpremVnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: aroServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource aroMasterSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: aroVnet
  name: 'master'
}

resource aroWorkerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: aroVnet
  name: 'worker'
}

resource onpremMasterSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: onpremVnet
  name: 'master'
}

resource onpremWorkerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: onpremVnet
  name: 'worker'
}

resource aroCluster 'Microsoft.RedHatOpenShift/openShiftClusters@2024-08-12-preview' = {
  name: aroClusterName
  location: location
  dependsOn: [
    aroContributor
    aroNetworkRole
  ]
  properties: {
    apiserverProfile: {
      visibility: 'Public'
    }
    clusterProfile: {
      domain: 'aro-${uniqueString(resourceGroup().id, aroClusterName)}'
      resourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/aro-managed-${uniqueString(resourceGroup().id, aroClusterName)}'
      fipsValidatedModules: 'Disabled'
      pullSecret: redHatPullSecret
      version: openShiftVersion
    }
    consoleProfile: {}
    ingressProfiles: [
      {
        name: 'default'
        visibility: 'Public'
      }
    ]
    masterProfile: {
      encryptionAtHost: 'Disabled'
      vmSize: aroMasterVmSize
      subnetId: aroMasterSubnet.id
    }
    networkProfile: {
      outboundType: 'Loadbalancer'
      podCidr: '10.128.0.0/14'
      serviceCidr: '172.30.0.0/16'
    }
    servicePrincipalProfile: {
      clientId: aroServicePrincipalClientId
      clientSecret: aroServicePrincipalClientSecret
    }
    workerProfiles: [
      {
        name: 'worker'
        count: 3
        encryptionAtHost: 'Disabled'
        vmSize: aroWorkerVmSize
        diskSizeGB: 128
        subnetId: aroWorkerSubnet.id
      }
    ]
  }
}

resource onpremCluster 'Microsoft.RedHatOpenShift/openShiftClusters@2024-08-12-preview' = {
  name: onpremClusterName
  location: location
  dependsOn: [
    aroContributor
    onpremNetworkRole
  ]
  properties: {
    apiserverProfile: {
      visibility: 'Public'
    }
    clusterProfile: {
      domain: 'aro-${uniqueString(resourceGroup().id, onpremClusterName)}'
      resourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/aro-managed-${uniqueString(resourceGroup().id, onpremClusterName)}'
      fipsValidatedModules: 'Disabled'
      pullSecret: redHatPullSecret
      version: openShiftVersion
    }
    consoleProfile: {}
    ingressProfiles: [
      {
        name: 'default'
        visibility: 'Public'
      }
    ]
    masterProfile: {
      encryptionAtHost: 'Disabled'
      vmSize: aroMasterVmSize
      subnetId: onpremMasterSubnet.id
    }
    networkProfile: {
      outboundType: 'Loadbalancer'
      podCidr: '10.132.0.0/14'
      serviceCidr: '172.31.0.0/16'
    }
    servicePrincipalProfile: {
      clientId: aroServicePrincipalClientId
      clientSecret: aroServicePrincipalClientSecret
    }
    workerProfiles: [
      {
        name: 'worker'
        count: 3
        encryptionAtHost: 'Disabled'
        vmSize: aroWorkerVmSize
        diskSizeGB: 128
        subnetId: onpremWorkerSubnet.id
      }
    ]
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'shop-app-identity'
  location: location
}

resource keyVaultReadRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appIdentity.name, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultWriterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, aroServicePrincipalObjectId, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalId: aroServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource aroFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: appIdentity
  name: 'aro-shop-api'
  properties: {
    issuer: aroCluster.properties.clusterProfile.oidcIssuer
    subject: 'system:serviceaccount:shop:shop-api'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource onpremFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: appIdentity
  name: 'onprem-shop-api'
  properties: {
    issuer: onpremCluster.properties.clusterProfile.oidcIssuer
    subject: 'system:serviceaccount:shop:shop-api'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'shop-logs'
  location: location
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource frontDoor 'Microsoft.Cdn/profiles@2025-04-15' = {
  name: frontDoorProfileName
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-04-15' = {
  parent: frontDoor
  name: frontDoorEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2025-04-15' = {
  parent: frontDoor
  name: 'shop-origins'
  properties: {
    healthProbeSettings: {
      probePath: '/readyz'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    loadBalancingSettings: {
      sampleSize: 1
      successfulSamplesRequired: 1
      additionalLatencyInMilliseconds: 0
    }
    sessionAffinityState: 'Disabled'
  }
}

output keyVaultName string = keyVault.name
output appIdentityClientId string = appIdentity.properties.clientId
output logAnalyticsWorkspaceId string = workspace.id
output frontDoorEndpointHost string = frontDoorEndpoint.properties.hostName
output aroClusterName string = aroCluster.name
output onpremClusterName string = onpremCluster.name

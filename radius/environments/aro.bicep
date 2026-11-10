extension radius

@description('Azure subscription containing the ARO cluster resources.')
param azureSubscriptionId string

@description('Azure resource group that owns the managed database resources.')
param azureResourceGroupName string

resource recipePack 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'shop-aro'
}

resource environment 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'aro'
  properties: {
    providers: {
      kubernetes: {
        namespace: 'shop'
      }
      azure: {
        subscriptionId: azureSubscriptionId
        resourceGroupName: azureResourceGroupName
      }
    }
    recipePacks: [
      recipePack.id
    ]
  }
}

targetScope = 'subscription'

@description('Full ID of the approved initiative assignment containing the two storage policy references below.')
param policyAssignmentId string

@description('Tenant-local object ID of the ARO resource provider, not a cluster service principal or application ID.')
param aroResourceProviderObjectId string

@description('Azure region whose ARO-provider storage requests are exempted.')
param location string

@description('Approved expiry in UTC ISO 8601 format. Expiry can affect ongoing cluster maintenance.')
param expiresOn string

resource storageWaiver 'Microsoft.Authorization/policyExemptions@2024-12-01-preview' = {
  name: 'aro-storage-${uniqueString(policyAssignmentId, aroResourceProviderObjectId, location)}'
  properties: {
    displayName: 'Temporary ARO-managed storage compatibility waiver'
    description: 'Approved temporary waiver for ARO-provider storage requests in the selected region. Applies to any matching ARO cluster in this subscription, not only the demo.'
    exemptionCategory: 'Waiver'
    assignmentScopeValidation: 'Default'
    policyAssignmentId: policyAssignmentId
    policyDefinitionReferenceIds: [
      'StorageAccountPublicNetworkModify'
      'StorageAccountDisableLocalAuth'
    ]
    expiresOn: expiresOn
    resourceSelectors: [
      {
        name: 'aroProviderStorageInRegion'
        selectors: [
          {
            kind: 'resourceType'
            in: [
              'Microsoft.Storage/storageAccounts'
            ]
          }
          {
            kind: 'resourceLocation'
            in: [
              location
            ]
          }
          {
            kind: 'UserPrincipalId'
            in: [
              aroResourceProviderObjectId
            ]
          }
        ]
      }
    ]
  }
}

output exemptionId string = storageWaiver.id

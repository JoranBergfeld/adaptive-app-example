targetScope = 'resourceGroup'

@description('Front Door profile provisioned by main.bicep. Deploy this route only after enabling an origin.')
param frontDoorProfileName string

@description('Endpoint name used when provisioning main.bicep.')
param frontDoorEndpointName string = 'shop'

resource frontDoor 'Microsoft.Cdn/profiles@2025-04-15' existing = {
  name: frontDoorProfileName
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-04-15' existing = {
  parent: frontDoor
  name: frontDoorEndpointName
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2025-04-15' existing = {
  parent: frontDoor
  name: 'shop-origins'
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2025-04-15' = {
  parent: frontDoorEndpoint
  name: 'shop'
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
    patternsToMatch: [
      '/*'
    ]
    supportedProtocols: [
      'Https'
      'Http'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
}

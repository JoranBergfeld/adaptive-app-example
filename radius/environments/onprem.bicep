extension radius

resource recipePack 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'shop-onprem-style'
}

resource environment 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'onprem'
  properties: {
    providers: {
      kubernetes: {
        namespace: 'shop'
      }
    }
    recipePacks: [
      recipePack.id
    ]
  }
}

extension radius

@description('Public Git branch or tag containing the Radius recipes in this repository.')
param recipeRef string = 'main'

resource onpremRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'shop-onprem-style'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'git::https://github.com/JoranBergfeld/adaptive-app-example.git//radius/recipes/onprem/postgresql?ref=${recipeRef}'
      }
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'git::https://github.com/JoranBergfeld/adaptive-app-example.git//radius/recipes/onprem/redis?ref=${recipeRef}'
      }
    }
  }
}

targetScope = 'resourceGroup'

@description('Location for DCE and DCR resources.')
param location string

@description('Name of the existing Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the custom table. Must end with _CL.')
param customTableName string = 'Locksmith2_CL'

@description('Name of the Data Collection Endpoint.')
param dataCollectionEndpointName string = 'dce-locksmith2'

@description('Name of the Data Collection Rule.')
param dataCollectionRuleName string = 'dcr-locksmith2'

@description('Custom stream used by the Log Ingestion API.')
param streamName string = 'Custom-Locksmith2Stream'

@description('Object ID of the managed identity that should ingest into the DCR. Leave empty to skip RBAC assignment.')
param managedIdentityPrincipalId string = ''

@description('Resource group of the Arc machine or VM identity source. Used only when managedIdentityPrincipalId is empty.')
param managedIdentityResourceGroupName string = ''

@description('Name of an Arc machine (Microsoft.HybridCompute/machines) whose system-assigned identity should ingest into the DCR.')
param managedIdentityArcMachineName string = ''

@description('Name of an Azure VM (Microsoft.Compute/virtualMachines) whose system-assigned identity should ingest into the DCR.')
param managedIdentityVmName string = ''

// Shared column definitions for the custom table and the DCR stream declaration.
// 'bool'/'boolean' and 'long' differ in name between the table schema and the DCR
// stream schema APIs, so the two variants below stay in lockstep intentionally.
var tableColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Technique', type: 'string' }
  { name: 'Forest', type: 'string' }
  { name: 'Name', type: 'string' }
  { name: 'DistinguishedName', type: 'string' }
  { name: 'ObjectClass', type: 'string' }
  { name: 'IdentityReference', type: 'string' }
  { name: 'IdentityReferenceSID', type: 'string' }
  { name: 'IdentityReferenceClass', type: 'string' }
  { name: 'ActiveDirectoryRights', type: 'string' }
  { name: 'AceObjectTypeGUID', type: 'string' }
  { name: 'AceObjectTypeName', type: 'string' }
  { name: 'Enabled', type: 'bool' }
  { name: 'EnabledOn', type: 'dynamic' }
  { name: 'CAFullName', type: 'string' }
  { name: 'Owner', type: 'string' }
  { name: 'HasNonStandardOwner', type: 'bool' }
  { name: 'MemberCount', type: 'long' }
  { name: 'Issue', type: 'string' }
  { name: 'Fix', type: 'string' }
  { name: 'Revert', type: 'string' }
]

var streamColumns = [
  for column in tableColumns: {
    name: column.name
    type: column.type == 'bool' ? 'boolean' : column.type
  }
]

var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: customTableName
  parent: workspace
  properties: {
    schema: {
      name: customTableName
      columns: tableColumns
    }
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dataCollectionEndpointName
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dataCollectionRuleName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: streamColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'lawDestination'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          streamName
        ]
        destinations: [
          'lawDestination'
        ]
        outputStream: 'Custom-${customTableName}'
        transformKql: 'source'
      }
    ]
  }
}

var arcMachineResourceId = !empty(managedIdentityArcMachineName) && !empty(managedIdentityResourceGroupName)
  ? resourceId(managedIdentityResourceGroupName, 'Microsoft.HybridCompute/machines', managedIdentityArcMachineName)
  : ''

var vmResourceId = !empty(managedIdentityVmName) && !empty(managedIdentityResourceGroupName)
  ? resourceId(managedIdentityResourceGroupName, 'Microsoft.Compute/virtualMachines', managedIdentityVmName)
  : ''

resource dcrIngestionRoleAssignmentFromPrincipalId 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(managedIdentityPrincipalId)) {
  name: guid(dcr.id, managedIdentityPrincipalId, monitoringMetricsPublisherRoleDefinitionId)
  scope: dcr
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource dcrIngestionRoleAssignmentFromArcMachine 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(managedIdentityPrincipalId) && !empty(managedIdentityArcMachineName) && !empty(managedIdentityResourceGroupName)) {
  name: guid(
    dcr.id,
    managedIdentityResourceGroupName,
    managedIdentityArcMachineName,
    monitoringMetricsPublisherRoleDefinitionId
  )
  scope: dcr
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: reference(arcMachineResourceId, '2023-03-15', 'Full').identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dcrIngestionRoleAssignmentFromVm 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(managedIdentityPrincipalId) && empty(managedIdentityArcMachineName) && !empty(managedIdentityVmName) && !empty(managedIdentityResourceGroupName)) {
  name: guid(
    dcr.id,
    managedIdentityResourceGroupName,
    managedIdentityVmName,
    monitoringMetricsPublisherRoleDefinitionId
  )
  scope: dcr
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: reference(vmResourceId, '2023-09-01', 'Full').identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output customTableResourceId string = customTable.id
output dataCollectionEndpointUri string = dce.properties.logsIngestion.endpoint
output dataCollectionRuleImmutableId string = dcr.properties.immutableId
output streamNameOut string = streamName
output dataCollectionRuleResourceId string = dcr.id

/*
Management platform: owns the management subscription. Deploy once, before the hub.
  az deployment sub create -n management-shared -l swedencentral -f platform/management/main.bicep -p platform/management/main.bicepparam
Holds the central Log Analytics workspace (Azure landing zone reference architecture). Platform resources,
such as the hub firewall, send their diagnostics here. Its names come from config/platform.bicep, where the hub finds them too.
*/

targetScope = 'subscription'

import { management } from '../../config/platform.bicep'

@description('Location for all management resources')
param location string = deployment().location

@description('Log Analytics retention in days. The first 31 days are free; the ALZ reference uses 365, raise it for production.')
param dataRetention int = 30

@description('Tags applied to all management resources')
param tags object = {}

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
// Fixed environment: management is shared platform infrastructure, like the hub
var environment = 'shared'
// Shared with the hub (firewall diagnostics), so defined once in config/platform.bicep
var resourceGroupName = management.resourceGroupName
var workspaceName = management.logAnalyticsWorkspaceName

// -------------------- MANAGEMENT RESOURCE GROUP (AVM) --------------------
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-management-${environment}'
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- LOG ANALYTICS WORKSPACE (AVM) --------------------
// Central workspace for platform diagnostics. Pay per GB ingested.
module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: workspaceName
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: workspaceName
    location: location
    tags: union(tags, { environment: environment })
    skuName: 'PerGB2018'
    dataRetention: dataRetention
    enableTelemetry: false
  }
}

output resourceGroupName string = rg.outputs.name
output logAnalyticsWorkspaceName string = workspace.outputs.name
output logAnalyticsWorkspaceResourceId string = workspace.outputs.resourceId
// Workspace (customer) ID, for az monitor log-analytics query -w
output logAnalyticsWorkspaceId string = workspace.outputs.logAnalyticsWorkspaceId

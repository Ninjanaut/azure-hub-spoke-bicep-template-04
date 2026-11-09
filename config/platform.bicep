/*
Shared platform values: the only place for names that more than one template or param file uses.
Not deployed. Templates and param files import from it, for example:
  import { config, hub } from '../config/platform.bicep'

platform.json vs platform.bicep:
- platform.json holds the values that differ per tenant or environment: tenant ID, subscription IDs, spoke address
  prefixes, region, management group prefix, test user, Entra ID group names and object IDs, SSH key path. Plain data, no logic.
  The scripts read it too (PowerShell can't read .bicep), and setup-entra.ps1 writes the group object IDs into it.
- platform.bicep (this file) holds the design, which stays the same in every environment: resource names,
  the hub address plan, the Private DNS zone list. It also computes what JSON can't: resource IDs, subnets,
  the firewall IP. Only Bicep reads it.

When to use which:
- A value you'd change when deploying to another tenant or subscription, or one a script needs -> platform.json.
- A name or design value that more than one template or param file uses, or a value computed from others -> here.
- A value only one template uses (Bastion, firewall, NSG names) -> that template, not here.
*/

// ==================== Config (platform.json) ====================

@export()
@description('config/platform.json as loaded: IDs and environment settings')
var config = loadJsonContent('platform.json')

// ==================== Management (platform/management) ====================

var managementResourceGroupName = 'rg-management-shared'
var logAnalyticsWorkspaceName = 'log-management-shared-${config.location}-001'

@export()
@description('Central Log Analytics workspace for platform diagnostics (platform/management)')
var management = {
  subscriptionId: config.management.subscriptionId
  resourceGroupName: managementResourceGroupName
  logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
  logAnalyticsWorkspaceResourceId: '/subscriptions/${config.management.subscriptionId}/resourceGroups/${managementResourceGroupName}/providers/Microsoft.OperationalInsights/workspaces/${logAnalyticsWorkspaceName}'
}

// ==================== Hub (platform/connectivity) ====================

var hubResourceGroupName = 'rg-hub-shared'
var hubVnetName = 'vnet-hub-shared-${config.location}-001'
var hubAddressPrefix = '10.0.0.0/22'
var firewallSubnetPrefix = cidrSubnet(hubAddressPrefix, 26, 0)
// DNS Private Resolver inbound endpoint subnet: 10.0.1.128/28, after GatewaySubnet (10.0.1.64/26)
var dnsResolverInboundSubnetPrefix = cidrSubnet(hubAddressPrefix, 28, 24)
var dnsResourceGroupName = 'rg-dns-shared'
var internalDnsZoneName = 'hubspoke.internal'
var privateDnsZoneIdPrefix = '/subscriptions/${config.connectivity.subscriptionId}/resourceGroups/${dnsResourceGroupName}/providers/Microsoft.Network/privateDnsZones'
// Private Link zones: the only list. The hub creates them and every landing zone links its VNET to them.
// Adding a zone means redeploying the hub, then every landing zone.
// Zone names are fixed by Azure (public cloud), not endpoints, so the hardcoded-URL rule doesn't apply
#disable-diagnostics no-hardcoded-env-urls
var privateLinkDnsZones = [
  'privatelink.blob.core.windows.net'
  'privatelink.file.core.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.database.windows.net'
]
#restore-diagnostics no-hardcoded-env-urls

@export()
@description('Hub network for the hub template and the landing zones (platform/connectivity)')
var hub = {
  subscriptionId: config.connectivity.subscriptionId
  resourceGroupName: hubResourceGroupName
  vnetName: hubVnetName
  vnetResourceId: '/subscriptions/${config.connectivity.subscriptionId}/resourceGroups/${hubResourceGroupName}/providers/Microsoft.Network/virtualNetworks/${hubVnetName}'
  addressPrefix: hubAddressPrefix
  firewallSubnetPrefix: firewallSubnetPrefix
  firewallManagementSubnetPrefix: cidrSubnet(hubAddressPrefix, 26, 1)
  // Azure gives the firewall the first usable address of AzureFirewallSubnet (10.0.0.4); spoke routes use it
  firewallPrivateIpAddress: cidrHost(firewallSubnetPrefix, 3)
  // GatewaySubnet: /26 as the Azure Architecture Center hub-spoke recommends (10.0.1.64/26)
  gatewaySubnetPrefix: cidrSubnet(hubAddressPrefix, 26, 5)
  // P2S VPN gateway. Landing zones read the flag too: their peerings use the hub's gateway (gateway transit),
  // which fails if it doesn't exist. To turn the VPN off, set false and redeploy every landing zone before deleting it.
  vpnGatewayEnabled: true
  // P2S client address pool: outside 10.0.0.0/16, so it never collides with a spoke
  vpnClientAddressPoolPrefix: '172.16.0.0/24'
  // Every spoke, for the GatewaySubnet routes that send VPN clients through the firewall.
  // Adding a landing zone means redeploying the hub before it.
  spokes: map(items(config.landingZones), spoke => { name: spoke.key, addressPrefix: spoke.value.addressPrefix })
  dnsResolverInboundSubnetPrefix: dnsResolverInboundSubnetPrefix
  // Static, so VPN client profiles keep working when the resolver is recreated (10.0.1.132)
  dnsResolverInboundIpAddress: cidrHost(dnsResolverInboundSubnetPrefix, 3)
  dnsResourceGroupName: dnsResourceGroupName
  internalDnsZoneName: internalDnsZoneName
  internalDnsZoneResourceId: '${privateDnsZoneIdPrefix}/${internalDnsZoneName}'
  privateLinkDnsZones: privateLinkDnsZones
  privateLinkDnsZoneResourceIds: map(privateLinkDnsZones, zone => '${privateDnsZoneIdPrefix}/${zone}')
}

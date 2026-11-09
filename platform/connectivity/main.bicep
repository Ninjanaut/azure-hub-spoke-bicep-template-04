/*
Connectivity platform: owns the connectivity subscription. Deploy once, after platform/management and before any landing zone.
  az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/main.bicepparam
Creates its own resource groups; add further platform resource groups and modules here the same way.
Names that landing zones also use (resource groups, VNET, address space, firewall IP, DNS zones) come from config/platform.bicep.
DNS: the Private DNS zones live in rg-dns-shared. Every VNET is linked to every zone and uses Azure-provided DNS;
this template links the hub, and each landing zone links its own VNET. P2S VPN clients can't reach Azure-provided DNS,
so they query the DNS Private Resolver's inbound endpoint in the hub, which answers from the zones linked to the hub.
P2S VPN: VPN clients reach the spokes through gateway transit (landing zones set it on their peerings) and the firewall
(GatewaySubnet route table), as in the Azure Firewall hybrid hub-spoke guidance.
*/

targetScope = 'subscription'

import { hub } from '../../config/platform.bicep'

@description('Location for all hub resources')
param location string = deployment().location

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Supernet containing the hub and all spokes. The firewall allows all traffic within it (spoke-to-spoke) and from it to the internet.')
param spokesAddressSpace string = '10.0.0.0/16'

@description('Resource ID of the central Log Analytics workspace for firewall diagnostics (from config/platform.bicep). Empty: no diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Deploy Azure Bastion. It can\'t be stopped; set false and delete it and its public IP to save cost (see README, Turn off Bastion only). The subnet and NSG stay.')
param deployBastion bool = true

@description('Object ID of the Entra ID group that gets Reader on the Bastion (e.g. sg-hub-shared-bastion-users). Landing zones\' VM admin login groups become members of it. Empty: no role assignment, and Contributor is enough to deploy.')
param bastionUsersGroupObjectId string = ''

@description('Deploy the P2S VPN gateway (from hub.vpnGatewayEnabled in config/platform.bicep, which landing zones read too). It can\'t be stopped; see "Turn off the P2S VPN" in CLAUDE.md. GatewaySubnet and its route table stay.')
param deployVpnGateway bool = false

@description('P2S VPN client address pool. Must not overlap with the hub, the spokes or the clients\' own networks.')
param vpnClientAddressPoolPrefix string = '172.16.0.0/24'

@description('Microsoft Entra tenant ID for P2S VPN sign-in (from config/platform.json)')
param tenantId string = tenant().tenantId

@description('Deploy the DNS Private Resolver that P2S VPN clients use for name resolution. It can\'t be stopped; set false and delete it to save cost (see "Turn off the DNS resolver" in CLAUDE.md). The subnet and NSG stay.')
param deployDnsResolver bool = false

@description('Tags applied to all hub resources')
param tags object = {}

// Shared with the landing zones, so defined once in config/platform.bicep
var resourceGroupName = hub.resourceGroupName
var vnetName = hub.vnetName
var addressPrefix = hub.addressPrefix
// AzureFirewallSubnet: first /26 of the hub; AzureFirewallManagementSubnet (Basic SKU): second /26
var firewallSubnetPrefix = hub.firewallSubnetPrefix
var firewallManagementSubnetPrefix = hub.firewallManagementSubnetPrefix
// Azure assigns the firewall the first usable address of AzureFirewallSubnet; this only names it for the outputs
var firewallPrivateIpAddress = hub.firewallPrivateIpAddress
var dnsResourceGroupName = hub.dnsResourceGroupName
// Internal zone for VM names; hub and spoke VNETs auto-register their VMs in it
var internalDnsZoneName = hub.internalDnsZoneName
// AzureBastionSubnet (/26 minimum): 10.0.1.0/26, after the two firewall subnets
var bastionSubnetPrefix = cidrSubnet(addressPrefix, 26, 4)
// GatewaySubnet 10.0.1.64/26, DNS resolver inbound subnet 10.0.1.128/28 with its static IP 10.0.1.132
var gatewaySubnetPrefix = hub.gatewaySubnetPrefix
var dnsResolverInboundSubnetPrefix = hub.dnsResolverInboundSubnetPrefix
var dnsResolverInboundIpAddress = hub.dnsResolverInboundIpAddress

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
// Fixed environment: the hub is shared platform infrastructure for prod and non-prod spokes
var environment = 'shared'
var firewallName = 'afw-hub-${environment}-${location}-${instance}'
var firewallPolicyName = 'afwp-hub-${environment}-${location}-${instance}'
var bastionName = 'bas-hub-${environment}-${location}-${instance}'
var bastionNsgName = 'nsg-bastion-${environment}-${location}-${instance}'
var vpnGatewayName = 'vgw-hub-${environment}-${location}-${instance}'
var gatewayRouteTableName = 'rt-gateway-${environment}-${location}-${instance}'
var dnsResolverName = 'dnspr-hub-${environment}-${location}-${instance}'
var dnsResolverInboundSubnetName = 'snet-dns-inbound-${environment}-${location}-${instance}'
var dnsResolverInboundNsgName = 'nsg-dns-inbound-${environment}-${location}-${instance}'
// Private Link zones for private endpoints. The list lives in config/platform.bicep because landing zones link to the same zones.
var privateLinkDnsZones = hub.privateLinkDnsZones
// CAF has no VNET link format; link-<VNET name without vnet->
var hubLinkName = 'link-hub-${environment}-${location}-${instance}'

// -------------------- HUB RESOURCE GROUP (AVM) --------------------
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-hub-${environment}'
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- DNS RESOURCE GROUP (AVM) --------------------
// Separate from the hub so DNS zones get their own RBAC and policy scope
module dnsRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-dns-${environment}'
  params: {
    name: dnsResourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- BASTION SUBNET NSG (AVM) --------------------
// Unlike the other NSGs, this one needs rules: an NSG on AzureBastionSubnet must contain all rules from
// https://learn.microsoft.com/azure/bastion/bastion-nsg, or Bastion loses connectivity and platform updates.
module bastionNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: bastionNsgName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: bastionNsgName
    location: location
    tags: union(tags, { environment: environment })
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- DNS RESOLVER INBOUND SUBNET NSG (AVM) --------------------
// Default rules only, like every workload subnet. AllowVnetInBound covers DNS queries from P2S clients (the client
// pool comes in through the gateway, so it's part of the VirtualNetwork service tag) and from peered spokes.
module dnsResolverInboundNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: dnsResolverInboundNsgName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: dnsResolverInboundNsgName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- GATEWAYSUBNET ROUTE TABLE (AVM) --------------------
// P2S clients learn the spoke prefixes through gateway transit. Without these routes the gateway would deliver their
// traffic straight over the peering; with them, traffic to the spokes goes through the firewall (filtered and logged).
// One route per spoke with its exact prefix: longest prefix wins, so a supernet such as 10.0.0.0/16 would lose to the
// spoke's peering route. Requests would bypass the firewall, and it would drop the replies (it never saw the flow start).
// The hub itself (10.0.0.0/22) has no route here, so the resolver and Bastion are reached directly.
// GatewaySubnet needs gateway route propagation on and must not have a 0.0.0.0/0 route.
module gatewayRouteTable 'br/public:avm/res/network/route-table:0.5.0' = {
  name: gatewayRouteTableName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: gatewayRouteTableName
    location: location
    tags: union(tags, { environment: environment })
    routes: [
      for spoke in hub.spokes: {
        name: '${spoke.name}-to-firewall'
        properties: {
          addressPrefix: spoke.addressPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIpAddress
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- HUB VNET (AVM) --------------------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-hub-${environment}-${location}-${instance}'
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: vnetName
    location: location
    tags: union(tags, { environment: environment })
    addressPrefixes: [
      addressPrefix
    ]
    subnets: [
      // Firewall subnets: names required by Azure Firewall (not CAF). NSGs aren't supported on them;
      // the firewall policy filters the traffic instead.
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: firewallSubnetPrefix
      }
      {
        // Basic SKU only: Azure uses it for the firewall's management traffic
        name: 'AzureFirewallManagementSubnet'
        addressPrefix: firewallManagementSubnetPrefix
      }
      {
        // Name required by Azure Bastion (not CAF)
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
        networkSecurityGroupResourceId: bastionNsg.outputs.resourceId
      }
      {
        // Name required by the VPN gateway (not CAF). No NSG: Azure doesn't support one on GatewaySubnet.
        // Created even without the gateway (deployVpnGateway), so the address plan doesn't move.
        name: 'GatewaySubnet'
        addressPrefix: gatewaySubnetPrefix
        routeTableResourceId: gatewayRouteTable.outputs.resourceId
      }
      {
        // DNS Private Resolver inbound endpoint; the subnet is dedicated to it (delegation)
        name: dnsResolverInboundSubnetName
        addressPrefix: dnsResolverInboundSubnetPrefix
        networkSecurityGroupResourceId: dnsResolverInboundNsg.outputs.resourceId
        delegation: 'Microsoft.Network/dnsResolvers'
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- BASTION (AVM) --------------------
// One Bastion for the hub and every peered spoke. Basic is the cheapest SKU that reaches peered VNETs
// and supports Microsoft Entra ID SSH in the portal; the native client (az network bastion ssh) needs Standard.
// Must be in the VNET's resource group. AVM creates the Standard/Static public IP.
// Optional (deployBastion): false doesn't delete an existing Bastion (incremental deployment); delete it with az network bastion delete.
module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = if (deployBastion) {
  name: bastionName
  scope: resourceGroup(resourceGroupName)
  params: {
    name: bastionName
    location: location
    tags: union(tags, { environment: environment })
    virtualNetworkResourceId: vnet.outputs.resourceId
    skuName: 'Basic'
    publicIPAddressObject: {
      name: 'pip-${bastionName}'
    }
    // Reader on the Bastion, needed for Entra ID sign-in. One spoke-agnostic group: landing zones add their
    // VM admin login groups as members (nested groups), so adding a spoke never touches this template, and the
    // assignment comes back whenever the Bastion is recreated. Needs RBAC Administrator (or Owner) on rg-hub-shared.
    roleAssignments: empty(bastionUsersGroupObjectId)
      ? []
      : [
          {
            roleDefinitionIdOrName: 'Reader'
            principalId: bastionUsersGroupObjectId
            principalType: 'Group'
            description: 'Use the hub Bastion for Entra ID sign-in (members: landing zone VM admin login groups)'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- PRIVATE DNS ZONES (AVM) --------------------
// Resolution needs a link on each VNET: Azure DNS (168.63.129.16) only answers from zones linked to the
// VM's own VNET, and peering doesn't share links. This links the hub; landing zones link themselves.
// Private Link zones: private endpoints in any spoke register their records here (DNS zone group)
module privateLinkZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for zone in privateLinkDnsZones: {
    name: take('pdnsz-${zone}', 64)
    scope: resourceGroup(dnsResourceGroupName)
    dependsOn: [
      dnsRg
    ]
    params: {
      name: zone
      tags: union(tags, { environment: environment })
      virtualNetworkLinks: [
        {
          name: hubLinkName
          virtualNetworkResourceId: vnet.outputs.resourceId
          registrationEnabled: false
        }
      ]
      enableTelemetry: false
    }
  }
]

// Internal zone for VM names. Each landing zone links its VNET with auto-registration.
module internalZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: take('pdnsz-${internalDnsZoneName}', 64)
  scope: resourceGroup(dnsResourceGroupName)
  dependsOn: [
    dnsRg
  ]
  params: {
    name: internalDnsZoneName
    tags: union(tags, { environment: environment })
    virtualNetworkLinks: [
      {
        name: hubLinkName
        virtualNetworkResourceId: vnet.outputs.resourceId
        // Registers hub VMs, if any are added later
        registrationEnabled: true
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- FIREWALL POLICY (AVM) --------------------
// Rules for the hub firewall. The firewall denies everything that no rule allows.
// Basic tier: threat intelligence can only alert, not deny.
// Add rules here; AVM replaces the rule collection groups on every deployment, so rules added in the portal are lost.
module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.6' = {
  name: firewallPolicyName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: firewallPolicyName
    location: location
    tags: union(tags, { environment: environment })
    tier: 'Basic'
    threatIntelMode: 'Alert'
    ruleCollectionGroups: [
      {
        name: 'rcg-hub-${environment}'
        priority: 200
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'rc-allow-spoke-to-spoke'
            priority: 100
            action: {
              type: 'Allow'
            }
            rules: [
              {
                // Spoke route tables send 0.0.0.0/0 here; the hub and a spoke's own VNET stay on more specific routes
                ruleType: 'NetworkRule'
                name: 'allow-spoke-to-spoke'
                ipProtocols: [
                  'Any'
                ]
                sourceAddresses: [
                  spokesAddressSpace
                ]
                destinationAddresses: [
                  spokesAddressSpace
                ]
                destinationPorts: [
                  '*'
                ]
              }
            ]
          }
          {
            // All spoke internet egress is allowed, SNATed to the firewall's public IP and logged (AZFWNetworkRule).
            // Spoke-to-spoke traffic matches the collection above first. To restrict egress later, replace this
            // collection with application rules (FQDNs) or narrower network rules; it's the only place to change.
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'rc-allow-spoke-internet'
            priority: 200
            action: {
              type: 'Allow'
            }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'allow-spoke-internet'
                ipProtocols: [
                  'Any'
                ]
                sourceAddresses: [
                  spokesAddressSpace
                ]
                destinationAddresses: [
                  '*'
                ]
                destinationPorts: [
                  '*'
                ]
              }
            ]
          }
          {
            // P2S VPN clients to the spokes. Narrow on purpose (least privilege): HTTPS and ping only, everything
            // else from VPN clients is denied by default and logged. Add ports here when a workload needs them.
            // No SSH: VM admins sign in through Bastion with Entra ID, not over the VPN.
            // Return traffic needs no rule (stateful). The client pool is RFC 1918, so it isn't SNATed.
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'rc-allow-p2s-to-spokes'
            priority: 300
            action: {
              type: 'Allow'
            }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'allow-p2s-https'
                ipProtocols: [
                  'TCP'
                ]
                sourceAddresses: [
                  vpnClientAddressPoolPrefix
                ]
                destinationAddresses: [
                  spokesAddressSpace
                ]
                destinationPorts: [
                  '443'
                ]
              }
              {
                ruleType: 'NetworkRule'
                name: 'allow-p2s-icmp'
                ipProtocols: [
                  'ICMP'
                ]
                sourceAddresses: [
                  vpnClientAddressPoolPrefix
                ]
                destinationAddresses: [
                  spokesAddressSpace
                ]
                destinationPorts: [
                  '*'
                ]
              }
            ]
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- FIREWALL (AVM) --------------------
// Forwards and filters all traffic leaving a spoke (other spokes and the internet); spoke route tables send 0.0.0.0/0 to its private IP.
// Private (RFC 1918) destinations aren't SNATed, so the target spoke sees the real source and replies through its own
// route back to the firewall. Internet-bound traffic is SNATed to the firewall's public IP (spoke subnets are private).
// Basic SKU: needs AzureFirewallManagementSubnet and a second public IP for management traffic. AVM creates both public IPs.
module firewall 'br/public:avm/res/network/azure-firewall:0.11.1' = {
  name: firewallName
  scope: resourceGroup(resourceGroupName)
  // Not in parallel with the Bastion, which also updates the hub VNET
  dependsOn: [
    bastion
  ]
  params: {
    name: firewallName
    location: location
    tags: union(tags, { environment: environment })
    azureSkuTier: 'Basic'
    virtualNetworkResourceId: vnet.outputs.resourceId
    firewallPolicyId: firewallPolicy.outputs.resourceId
    threatIntelMode: 'Alert'
    publicIPAddressObject: {
      name: 'pip-${firewallName}'
    }
    managementIPAddressObject: {
      name: 'pip-afw-mgmt-hub-${environment}-${location}-${instance}'
    }
    // Non-zonal: enough for a PoC
    availabilityZones: []
    // Central workspace in the management subscription (ALZ). All logs and metrics, into resource-specific tables (AZFW*).
    diagnosticSettings: empty(logAnalyticsWorkspaceResourceId)
      ? []
      : [
          {
            workspaceResourceId: logAnalyticsWorkspaceResourceId
            logAnalyticsDestinationType: 'Dedicated'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- P2S VPN GATEWAY (AVM) --------------------
// Point-to-site VPN with Microsoft Entra ID sign-in (OpenVPN + Azure VPN Client; MFA and Conditional Access apply).
// VpnGw1AZ: the cheapest SKU with OpenVPN and Entra ID (Basic has neither), and zone-redundant at no extra cost.
// Active-active (ALZ resilience recommendation): both instances carry traffic and clients fail over automatically;
// the only extra cost is the second public IP. No BGP: nothing peers with it yet (add it for a BGP S2S VPN later).
// Clients reach the spokes through gateway transit (set by the landing zones) and the GatewaySubnet route table.
// Not in parallel with the firewall, which also updates the hub VNET. Takes about 30-45 minutes.
// Optional (deployVpnGateway): false doesn't delete an existing gateway; see "Turn off the P2S VPN" in CLAUDE.md.
module vpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.12.0' = if (deployVpnGateway) {
  name: vpnGatewayName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    firewall
  ]
  params: {
    name: vpnGatewayName
    location: location
    tags: union(tags, { environment: environment })
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    skuName: 'VpnGw1AZ'
    vpnGatewayGeneration: 'Generation1'
    virtualNetworkResourceId: vnet.outputs.resourceId
    clusterSettings: {
      clusterMode: 'activeActiveNoBgp'
      secondPipName: 'pip-${vpnGatewayName}-02'
    }
    // AVM creates both Standard public IPs, zone-redundant like the gateway
    primaryPublicIPName: 'pip-${vpnGatewayName}-01'
    publicIpAvailabilityZones: [
      1
      2
      3
    ]
    vpnClientAddressPoolPrefix: vpnClientAddressPoolPrefix
    // Entra ID only (no certificates); Entra ID requires OpenVPN. The audience is the Microsoft-registered Azure VPN
    // Client app, which has global consent, so no app registration is needed. Every user in the tenant can connect;
    // the firewall (rc-allow-p2s-to-spokes) and the VM login roles limit what they reach.
    vpnClientAadConfiguration: {
      // az.environment(): the template's own environment variable ('shared') hides the function
      aadTenant: '${az.environment().authentication.loginEndpoint}${tenantId}/'
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
      aadAudience: 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
      vpnAuthenticationTypes: [
        'AAD'
      ]
      vpnClientProtocols: [
        'OpenVPN'
      ]
    }
    // Central workspace (ALZ): all logs (GatewayDiagnosticLog, P2SDiagnosticLog, ...) and metrics. The VPN gateway
    // writes to the AzureDiagnostics table; it has no resource-specific tables like the firewall.
    diagnosticSettings: empty(logAnalyticsWorkspaceResourceId)
      ? []
      : [
          {
            workspaceResourceId: logAnalyticsWorkspaceResourceId
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- DNS PRIVATE RESOLVER (AVM) --------------------
// P2S clients can't reach Azure-provided DNS (168.63.129.16), so they query the inbound endpoint, which answers
// from the zones linked to the hub VNET (all of them: hubspoke.internal and the Private Link zones) and from
// public DNS. Clients get its IP from their VPN profile (see "Connect with the P2S VPN" in CLAUDE.md).
// Inbound endpoint only: an outbound endpoint and forwarding ruleset are for on-premises DNS, which doesn't exist yet.
// Static IP, so a recreated resolver keeps the address in the client profiles.
// Optional (deployDnsResolver): false doesn't delete an existing resolver; see "Turn off the DNS resolver" in CLAUDE.md.
module dnsResolver 'br/public:avm/res/network/dns-resolver:0.5.8' = if (deployDnsResolver) {
  name: dnsResolverName
  scope: resourceGroup(resourceGroupName)
  // One hub VNET update at a time (the gateway, if any, runs after the firewall)
  dependsOn: [
    firewall
    vpnGateway
  ]
  params: {
    name: dnsResolverName
    location: location
    tags: union(tags, { environment: environment })
    virtualNetworkResourceId: vnet.outputs.resourceId
    inboundEndpoints: [
      {
        name: 'in-${dnsResolverName}'
        subnetResourceId: '${vnet.outputs.resourceId}/subnets/${dnsResolverInboundSubnetName}'
        privateIpAllocationMethod: 'Static'
        privateIpAddress: dnsResolverInboundIpAddress
      }
    ]
    enableTelemetry: false
  }
}

// Values needed by landing zones
output resourceGroupName string = rg.outputs.name
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output firewallName string = firewall.outputs.name
output firewallPolicyName string = firewallPolicy.outputs.name
// Assigned by Azure; landing zones use firewallPrivateIpAddress from config/platform.bicep, so check that the two match
output firewallPrivateIpAddress string = firewall.outputs.privateIp
output expectedFirewallPrivateIpAddress string = firewallPrivateIpAddress
output bastionName string = deployBastion ? bastion!.outputs.name : ''
output vpnGatewayName string = deployVpnGateway ? vpnGateway!.outputs.name : ''
// The DNS server for P2S VPN client profiles
output dnsResolverInboundIpAddress string = deployDnsResolver ? dnsResolverInboundIpAddress : ''
output dnsResourceGroupName string = dnsRg.outputs.name
output internalDnsZoneResourceId string = internalZone.outputs.resourceId

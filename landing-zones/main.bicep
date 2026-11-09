/*
Landing zone (spoke): resource group + route table + NSG + VNET, peered with the hub in both directions,
plus an optional connectivity test VM (deployTestVm). Owned by the platform team.
Deploy once per landing zone, after platform/connectivity.
  az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1-dev.bicepparam
The hub → spoke peering is created in the hub resource group (possibly another subscription),
so the deploying identity needs network write access there too. The same goes for the Private DNS
zone links in the DNS resource group.
*/

targetScope = 'subscription'

@description('Short spoke purpose used in resource names, e.g. "app1"')
param spokeName string

@description('Spoke environment (CAF environment component). "shared" is reserved for the hub.')
@allowed([
  'prod'
  'dev'
  'test'
  'qa'
  'stage'
])
param environment string

@description('Location for all spoke resources')
param location string = deployment().location

@description('Spoke resource group')
param resourceGroupName string = 'rg-spoke-${spokeName}-${environment}'

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Spoke VNET address space. Must not overlap with the hub or any other spoke.')
param addressPrefix string

@description('Workload subnet prefix')
param workloadSubnetPrefix string = cidrSubnet(addressPrefix, 24, 0)

@description('Resource ID of the hub VNET (from config/platform.bicep)')
param hubVnetResourceId string

@description('Private IP of the hub firewall (from config/platform.bicep)')
param firewallPrivateIpAddress string

@description('Resource ID of the internal Private DNS zone the spoke VMs register in (from config/platform.bicep)')
param internalDnsZoneResourceId string

@description('Resource IDs of the Private Link DNS zones the spoke VNET is linked to (from config/platform.bicep)')
param privateLinkDnsZoneResourceIds string[]

@description('Use the hub\'s VPN gateway (gateway transit), so P2S VPN clients get a route to this spoke. Requires the gateway to exist (from hub.vpnGatewayEnabled in config/platform.bicep).')
param useHubVpnGateway bool = false

@description('Tags applied to all spoke resources')
param tags object = {}

@description('Object ID of the Entra ID group whose members may sign in to this spoke\'s VMs through Bastion (e.g. sg-app1-dev-vm-admin-login). Empty: no role assignments, and Contributor is enough to deploy.')
param vmAdminLoginGroupObjectId string = ''

@description('Deploy a small Linux VM in the workload subnet to test spoke-to-spoke routing')
param deployTestVm bool = false

@description('Test VM size. D2pls_v6 (2 vCPU, 4 GiB, Arm64, Dplsv6 family) supports accelerated networking and has default quota; older sizes such as B1s are not offered to the spoke subscriptions in Sweden Central.')
param testVmSize string = 'Standard_D2pls_v6'

@description('Ubuntu 24.04 image SKU; must match the CPU architecture of testVmSize ("server-arm64" for Arm64 sizes, "server" for x64)')
param testVmImageSku string = 'server-arm64'

@description('Admin user on the test VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the test VM admin user. Required when deployTestVm is true.')
@secure()
param adminSshPublicKey string = ''

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
var nameSuffix = '${spokeName}-${environment}-${location}-${instance}'
var vnetName = 'vnet-${nameSuffix}'
var testVmName = 'vm-conntest-${nameSuffix}'

// CAF has no peering format; mirrors the VPN connection one: peer-<local>-to-<remote>
var hubPart = replace(last(split(hubVnetResourceId, '/')), 'vnet-', '')
var spokePart = nameSuffix

// -------------------- SPOKE RESOURCE GROUP (AVM) --------------------
// VM sign-in through Bastion with Entra ID: the login role and Reader (VM, NIC, VNet) for the spoke's group.
// Reader on the Bastion comes from the hub: add the group as a member of the hub's Bastion users group.
// Assigning roles needs Role Based Access Control Administrator (or Owner) on the spoke subscription.
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: resourceGroupName
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    roleAssignments: empty(vmAdminLoginGroupObjectId)
      ? []
      : [
          {
            // Built-in role GUID: AVM maps only a few role names (Owner, Contributor, Reader, ...), not this one
            roleDefinitionIdOrName: '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Virtual Machine Administrator Login
            principalId: vmAdminLoginGroupObjectId
            principalType: 'Group'
            description: 'Bastion Entra ID sign-in to ${spokeName}-${environment} VMs'
          }
          {
            roleDefinitionIdOrName: 'Reader'
            principalId: vmAdminLoginGroupObjectId
            principalType: 'Group'
            description: 'Bastion Entra ID sign-in to ${spokeName}-${environment} VMs (VM, NIC, VNet)'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- SPOKE ROUTE TABLE (AVM) --------------------
// Forced egress (ALZ hub-and-spoke): one default route sends everything that leaves the spoke to the hub firewall,
// both other spokes and the internet. The spoke's own VNET route and the hub's peering route are more specific
// (longest prefix wins), so traffic inside the spoke and to the hub (Bastion) doesn't go through the firewall.
// Gateway route propagation is off: with gateway transit the spoke would otherwise learn the P2S client pool from the
// hub's VPN gateway and reply to VPN clients directly, bypassing the firewall (asymmetric). Off, replies follow 0.0.0.0/0.
module routeTable 'br/public:avm/res/network/route-table:0.5.0' = {
  name: take('rt-${nameSuffix}', 64)
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: 'rt-${nameSuffix}'
    location: location
    tags: union(tags, { environment: environment })
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIpAddress
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- WORKLOAD SUBNET NSG (AVM) --------------------
// Default rules only. Other spokes aren't peered with this one, but their traffic is still allowed by
// AllowVnetInBound: UDR prefixes are part of the VirtualNetwork service tag, and with the 0.0.0.0/0 route
// the tag effectively matches any address. So write rules with explicit prefixes, not the VirtualNetwork tag.
// Add rules here as securityRules; they replace all custom rules on each deployment.
module nsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: take('nsg-${nameSuffix}', 64)
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: 'nsg-${nameSuffix}'
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- SPOKE VNET + PEERINGS (AVM) --------------------
// Deployment names are limited to 64 chars (peering names to 80)
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: take('vnet-${nameSuffix}', 64)
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
    // No dnsServers: Azure-provided DNS answers from the zones linked below
    subnets: [
      {
        name: 'snet-${nameSuffix}'
        addressPrefix: workloadSubnetPrefix
        routeTableResourceId: routeTable.outputs.resourceId
        networkSecurityGroupResourceId: nsg.outputs.resourceId
        // Private subnet: no implicit default outbound access, so the internet is only reachable through the
        // firewall route. If the route is removed, VMs lose the internet instead of silently going out directly.
        // A redeploy also changes it on an existing subnet (verified, despite AVM's "creation only" note), but running
        // VMs keep their old outbound access until they're deallocated and started again, or recreated.
        defaultOutboundAccess: false
      }
    ]
    peerings: [
      {
        // Spoke → hub, created on the spoke VNET
        name: 'peer-${spokePart}-to-${hubPart}'
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowVirtualNetworkAccess: true
        // Required for traffic through the hub firewall (other spokes, and internet replies)
        allowForwardedTraffic: true
        allowGatewayTransit: false
        // Gateway transit: P2S VPN clients get a route to this spoke only when it uses the hub's gateway.
        // Fails if the hub has no gateway, hence the flag from config/platform.bicep.
        useRemoteGateways: useHubVpnGateway
        // Hub → spoke, created on the hub VNET by a module scoped to the hub resource group
        remotePeeringEnabled: true
        remotePeeringName: 'peer-${hubPart}-to-${spokePart}'
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: useHubVpnGateway
        remotePeeringUseRemoteGateways: false
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- PRIVATE DNS ZONE LINKS (AVM) --------------------
// Azure DNS only answers from zones linked to the VM's own VNET (peering doesn't share links), so the
// spoke links itself to every shared zone. Created in the DNS resource group (possibly another
// subscription, parsed from the zone ID), like the hub → spoke peering. Other VNETs aren't touched.

// Internal zone: resolution plus auto-registration of the spoke's VMs
module internalZoneLink 'br/public:avm/res/network/private-dns-zone/virtual-network-link:0.1.0' = {
  name: take('link-${nameSuffix}', 64)
  scope: resourceGroup(split(internalDnsZoneResourceId, '/')[2], split(internalDnsZoneResourceId, '/')[4])
  params: {
    name: 'link-${spokePart}'
    privateDnsZoneName: last(split(internalDnsZoneResourceId, '/'))
    virtualNetworkResourceId: vnet.outputs.resourceId
    registrationEnabled: true
    enableTelemetry: false
  }
}

// Private Link zones: resolution only (private endpoints register through their DNS zone group)
module privateLinkZoneLinks 'br/public:avm/res/network/private-dns-zone/virtual-network-link:0.1.0' = [
  for (zoneId, i) in privateLinkDnsZoneResourceIds: {
    // Index keeps deployment names unique within 64 chars
    name: '${take('link-${nameSuffix}', 60)}-${i}'
    scope: resourceGroup(split(zoneId, '/')[2], split(zoneId, '/')[4])
    params: {
      name: 'link-${spokePart}'
      privateDnsZoneName: last(split(zoneId, '/'))
      virtualNetworkResourceId: vnet.outputs.resourceId
      registrationEnabled: false
      enableTelemetry: false
    }
  }
]

// -------------------- CONNECTIVITY TEST VM (AVM, optional) --------------------
// Throwaway VM for testing spoke-to-spoke routing. Setting deployTestVm back to false doesn't remove it
// (incremental deployment); delete it with az vm delete (its NIC and disk go with it).
// No public IP; sign in through the hub Bastion with Entra ID, or use `az vm run-command invoke`.
// Internet egress (apt, the Entra login extension package) goes through the hub firewall.
// Bastion reaches it over the hub peering; the subnet NSG's default AllowVnetInBound allows SSH from AzureBastionSubnet.
module testVm 'br/public:avm/res/compute/virtual-machine:0.22.3' = if (deployTestVm) {
  name: take(testVmName, 64)
  scope: resourceGroup(resourceGroupName)
  params: {
    name: testVmName
    location: location
    tags: union(tags, { environment: environment, purpose: 'connectivity-test' })
    // Microsoft Entra ID SSH login needs a system-assigned identity; the extension is the testVmAadLogin module below
    managedIdentities: {
      systemAssigned: true
    }
    vmSize: testVmSize
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: testVmImageSku
      version: 'latest'
    }
    osDisk: {
      diskSizeGB: 30
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        enableAcceleratedNetworking: true
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: vnet.outputs.subnetResourceIds[0]
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// Microsoft Entra ID SSH login extension, deployed separately instead of AVM's extensionAadJoinConfig: that one
// hardcodes the type 'AADSSHLoginforLinux' (lowercase f) and names it 'AADLogin'. It works on the VM, but the
// portal's Bastion page doesn't recognize it and doesn't offer Entra ID sign-in. Name and type here match what
// the portal and az vm extension set create. Changing extensions needs the VM running (az vm start).
module testVmAadLogin 'br/public:avm/res/compute/virtual-machine/extension:0.1.0' = if (deployTestVm) {
  name: take('${testVmName}-aadsshlogin', 64)
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualMachineName: testVm!.outputs.name
    name: 'AADSSHLoginForLinux'
    location: location
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    tags: union(tags, { environment: environment, purpose: 'connectivity-test' })
    enableTelemetry: false
  }
}

output resourceGroupName string = rg.outputs.name
output vnetName string = vnet.outputs.name
output vnetId string = vnet.outputs.resourceId
output workloadSubnetId string = vnet.outputs.subnetResourceIds[0]
output nsgName string = nsg.outputs.name
output internalDnsZoneLinkName string = internalZoneLink.outputs.name
output testVmName string = deployTestVm ? testVmName : ''
output testVmFqdn string = deployTestVm ? '${testVmName}.${last(split(internalDnsZoneResourceId, '/'))}' : ''
output testVmPrivateIpAddress string = deployTestVm
  ? (testVm!.outputs.nicConfigurations[0].ipConfigurations[0].?privateIP ?? '')
  : ''

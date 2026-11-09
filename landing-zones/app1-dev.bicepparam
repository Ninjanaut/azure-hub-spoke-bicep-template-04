using 'main.bicep'

import { config, hub } from '../config/platform.bicep'

param spokeName = 'app1'
param environment = 'dev'
param addressPrefix = config.landingZones['app1-dev'].addressPrefix
param hubVnetResourceId = hub.vnetResourceId
param firewallPrivateIpAddress = hub.firewallPrivateIpAddress
param privateLinkDnsZoneResourceIds = hub.privateLinkDnsZoneResourceIds
param internalDnsZoneResourceId = hub.internalDnsZoneResourceId
// Gateway transit through the hub's P2S VPN gateway; must match whether the hub has one
param useHubVpnGateway = hub.vpnGatewayEnabled
// Entra ID group whose members may sign in to this spoke's VMs through Bastion. Empty: no role assignments.
// From config/platform.json (landingZones.app1-dev), written by scripts/setup-entra.ps1.
param vmAdminLoginGroupObjectId = config.landingZones['app1-dev'].vmAdminLoginGroup.objectId
param tags = {
  workload: 'app1'
}

// Connectivity test VM. Its SSH public key is read at deploy time so it stays out of the repo.
// scripts/deploy.ps1 sets $env:ADMIN_SSH_PUBLIC_KEY from sshPublicKeyPath in config/platform.json.
param deployTestVm = true
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')

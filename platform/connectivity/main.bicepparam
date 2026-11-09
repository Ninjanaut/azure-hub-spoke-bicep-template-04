using 'main.bicep'

import { config, hub, management } from '../../config/platform.bicep'

param tags = {
  workload: 'hub-spoke'
}
// Azure Bastion can't be stopped (about $140/month). To turn it off: set false, then delete it
// (see "Cleanup and cost" in CLAUDE.md). To turn it back on: set true and redeploy the hub.
param deployBastion = true
// Entra ID group with Reader on the Bastion; landing zone VM admin login groups are its members (see "Sign in to a VM" in CLAUDE.md).
// From config/platform.json, written by scripts/setup-entra.ps1. Empty: no role assignment.
param bastionUsersGroupObjectId = config.connectivity.bastionUsersGroup.objectId
// P2S VPN gateway (VpnGw1AZ, about $140/month plus three public IPs; can't be stopped). The flag lives in
// config/platform.bicep (hub.vpnGatewayEnabled) because the landing zones' peerings depend on it too.
// To turn it off, see "Turn off the P2S VPN" in CLAUDE.md.
param deployVpnGateway = hub.vpnGatewayEnabled
param vpnClientAddressPoolPrefix = hub.vpnClientAddressPoolPrefix
param tenantId = config.tenantId
// DNS Private Resolver for P2S VPN clients (about $180/month; can't be stopped). To turn it off: set false, then delete it
// (see "Turn off the DNS resolver" in CLAUDE.md). To turn it back on: set true and redeploy the hub (same IP, 10.0.1.132).
param deployDnsResolver = true
// Firewall diagnostics go to the central workspace in the management subscription (deploy platform/management first)
param logAnalyticsWorkspaceResourceId = management.logAnalyticsWorkspaceResourceId

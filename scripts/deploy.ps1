# All deployments in order: management -> hub -> landing zones (one at a time). Safe to rerun.
# Before the first run: scripts/setup-entra.ps1 and scripts/setup-management-groups.ps1.
# Dry run: replace "create" with "what-if" in a line.
# Run from the repo root after: az login --tenant <tenantId from config/platform.json>
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$location = $config.location

# SSH public key for the spokes' test VMs (the param files read it)
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content ($config.sshPublicKeyPath -replace '^~', $HOME)

# Management: central Log Analytics workspace
az deployment sub create --subscription $config.management.subscriptionId -n management-shared -l $location -f platform/management/main.bicep -p platform/management/main.bicepparam

# The hub firewall's diagnostic setting needs this provider in the workspace's subscription
az provider register -n Microsoft.Insights --subscription $config.management.subscriptionId --wait

# Hub: firewall, Bastion, Private DNS, P2S VPN gateway, DNS resolver (about 45 minutes with the VPN gateway).
# Before the landing zones: with the VPN gateway on, their peerings use it (gateway transit) and fail without it.
# Rerun before adding a landing zone: its GatewaySubnet route sends VPN traffic through the firewall.
az deployment sub create --subscription $config.connectivity.subscriptionId -n hub-shared -l $location -f platform/connectivity/main.bicep -p platform/connectivity/main.bicepparam

# Expect 10.0.0.4, the IP the spokes route to (hub.firewallPrivateIpAddress in config/platform.bicep)
# az deployment sub show --subscription $config.connectivity.subscriptionId -n hub-shared --query properties.outputs.firewallPrivateIpAddress.value -o tsv

# P2S VPN client profile: prints a URL to a zip with AzureVPN/azurevpnconfig.xml (see "Connect with the P2S VPN" in CLAUDE.md).
# Download it again after adding a landing zone, so Windows clients get the new spoke's route.
# az network vnet-gateway vpn-client generate --subscription $config.connectivity.subscriptionId -g rg-hub-shared -n "vgw-hub-shared-$location-001" -o tsv

# Landing zones
az deployment sub create --subscription $config.landingZones.'app1-dev'.subscriptionId -n spoke-app1-dev -l $location -f landing-zones/main.bicep -p landing-zones/app1-dev.bicepparam
az deployment sub create --subscription $config.landingZones.'app2-dev'.subscriptionId -n spoke-app2-dev -l $location -f landing-zones/main.bicep -p landing-zones/app2-dev.bicepparam

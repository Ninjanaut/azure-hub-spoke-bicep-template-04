# This script:
# 1. Creates the ALZ-style management group hierarchy and moves the subscriptions into it.
# 2. Must be run before the policy deployment (before deploy-governance.ps1, which assigns the Corp policy).
# 3. Requires Management Group Contributor on the tenant root group and Owner on the subscriptions (to move them).
# 4. Exits at the guard check if any of the management groups already exists.
#
# Run it from the repo root after signing in with: az login --tenant <tenantId from config/platform.json>

# Load config (management group prefix and subscription IDs)
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$prefix = $config.managementGroups.prefix

# Guard: this script only creates resources, so stop if any of the management groups already exists.
# az wouldn't duplicate them (the name is the ID), but it would reset their display name and parent.
$names = $prefix, "$prefix-platform", "$prefix-connectivity", "$prefix-management", "$prefix-decommissioned", "$prefix-landingzones", "$prefix-corp"
$existing = az account management-group list --query '[].name' -o tsv | Where-Object { $_ -in $names }
if ($existing) {
  Write-Host "Already exist, nothing created: $($existing -join ', ')"
  return
}

# Top-level management group, under the tenant root group
az account management-group create --name $prefix --display-name $config.managementGroups.rootDisplayName

# Platform landing zones
az account management-group create --name "$prefix-platform" --display-name "Platform" --parent $prefix
az account management-group create --name "$prefix-connectivity" --display-name "Connectivity" --parent "$prefix-platform"
az account management-group create --name "$prefix-management" --display-name "Management" --parent "$prefix-platform"
az account management-group create --name "$prefix-decommissioned" --display-name "Decommissioned" --parent $prefix

# Workload landing zones
az account management-group create --name "$prefix-landingzones" --display-name "Workload landing zones" --parent $prefix
az account management-group create --name "$prefix-corp" --display-name "Corp" --parent "$prefix-landingzones"

# Subscriptions. Only the spokes go under Corp: the connectivity subscription needs public IPs (firewall, Bastion).
az account management-group subscription add --name "$prefix-connectivity" --subscription $config.connectivity.subscriptionId
az account management-group subscription add --name "$prefix-management" --subscription $config.management.subscriptionId
az account management-group subscription add --name "$prefix-corp" --subscription $config.landingZones.'app1-dev'.subscriptionId
az account management-group subscription add --name "$prefix-corp" --subscription $config.landingZones.'app2-dev'.subscriptionId

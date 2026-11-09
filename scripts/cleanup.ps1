# Deletes the deployed resources, in reverse order. Spokes first: their peerings and DNS zone links point into the hub.
# Deleting rg-hub-shared takes a while (firewall, Bastion).
# Run from the repo root after: az login --tenant <tenantId from config/platform.json>
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$prefix = $config.managementGroups.prefix

az group delete -n rg-spoke-app1-dev --yes --subscription $config.landingZones.'app1-dev'.subscriptionId
az group delete -n rg-spoke-app2-dev --yes --subscription $config.landingZones.'app2-dev'.subscriptionId
az group delete -n rg-hub-shared --yes --subscription $config.connectivity.subscriptionId
az group delete -n rg-dns-shared --yes --subscription $config.connectivity.subscriptionId
az group delete -n rg-management-shared --yes --subscription $config.management.subscriptionId

# Also remove the Corp policy and the management groups: uncomment.
# Removing a subscription from a management group moves it back to the tenant root group; a management group must be empty to delete it.
# $corpScope = "/providers/Microsoft.Management/managementGroups/$prefix-corp"
# az policy assignment delete --name Deny-Public-IP --scope $corpScope
# az policy assignment delete --name Deny-Public-IP-On-NIC --scope $corpScope
# az policy assignment delete --name Deny-Subnet-Without-Udr --scope $corpScope
# az policy definition delete --name Deny-Subnet-Without-Udr --management-group "$prefix-corp"
# az account management-group subscription remove --name "$prefix-corp" --subscription $config.landingZones.'app1-dev'.subscriptionId
# az account management-group subscription remove --name "$prefix-corp" --subscription $config.landingZones.'app2-dev'.subscriptionId
# az account management-group subscription remove --name "$prefix-connectivity" --subscription $config.connectivity.subscriptionId
# az account management-group subscription remove --name "$prefix-management" --subscription $config.management.subscriptionId
# az account management-group delete --name "$prefix-corp"
# az account management-group delete --name "$prefix-landingzones"
# az account management-group delete --name "$prefix-decommissioned"
# az account management-group delete --name "$prefix-connectivity"
# az account management-group delete --name "$prefix-management"
# az account management-group delete --name "$prefix-platform"
# az account management-group delete --name $prefix

# Also remove the Entra ID test user and groups: uncomment. Then clear their objectId values in config/platform.json.
# az ad user delete --id $config.testUserUpn
# az ad group delete --group $config.connectivity.bastionUsersGroup.name
# az ad group delete --group $config.landingZones.'app1-dev'.vmAdminLoginGroup.name
# az ad group delete --group $config.landingZones.'app2-dev'.vmAdminLoginGroup.name

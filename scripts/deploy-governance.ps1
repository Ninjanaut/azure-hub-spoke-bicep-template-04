# This script:
# 1. Assigns the Corp policies (Deny-Public-IP, Deny-Public-IP-On-NIC, Deny-Subnet-Without-Udr) to the Corp management group,
#    and registers Microsoft.PolicyInsights in the spoke subscriptions so the portal shows their compliance.
# 2. Must be run after setup-management-groups.ps1 (the Corp management group must exist). Safe to rerun:
#    run it again after changing a policy in platform/governance/mgmt-groups/corp.
# 3. Requires Resource Policy Contributor on the Corp management group.
# 4. Dry run: replace "create" with "what-if".
#
# Run it from the repo root after signing in with: az login --tenant <tenantId from config/platform.json>

# Load config (management group prefix and location)
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$prefix = $config.managementGroups.prefix

# Compliance data (Policy -> Compliance) needs this provider in every subscription under Corp; nothing registers it automatically
az provider register -n Microsoft.PolicyInsights --subscription $config.landingZones.'app1-dev'.subscriptionId --wait
az provider register -n Microsoft.PolicyInsights --subscription $config.landingZones.'app2-dev'.subscriptionId --wait

# Corp policy. For a first run that only reports, set enforcementMode = 'DoNotEnforce' in the param file.
az deployment mg create -n governance-corp -m "$prefix-corp" -l $config.location -f platform/governance/mgmt-groups/corp/main.bicep -p platform/governance/mgmt-groups/corp/main.bicepparam

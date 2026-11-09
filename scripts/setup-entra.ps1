# This script:
# 1. Creates the test user and the security groups needed for admin login to the app1 and app2 virtual machines.
# 2. Must be run before the first deployment.
# 3. Requires the person running it to have the Groups Administrator and User Administrator roles in Entra ID.
# 4. Exits at the guard check if the user or any of the groups already exists.
#
# Run it from the repo root after signing in with: az login --tenant <tenantId from config/platform.json>

# Load config (user name and group names to create)
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$bastionUsersGroup = $config.connectivity.bastionUsersGroup
$app1AdminLoginGroup = $config.landingZones.'app1-dev'.vmAdminLoginGroup
$app2AdminLoginGroup = $config.landingZones.'app2-dev'.vmAdminLoginGroup

# Guard: this script only creates resources, so stop if the test user or any of the groups already exists.
# Otherwise Entra ID would create a duplicate with the same name but a different object ID.
# When the user or a group is not found, az returns nothing.
$existing = @(
  az ad user list --upn $config.testUserUpn --query '[].userPrincipalName' -o tsv
  az ad group list --filter "displayName eq '$($bastionUsersGroup.name)'" --query '[].displayName' -o tsv
  az ad group list --filter "displayName eq '$($app1AdminLoginGroup.name)'" --query '[].displayName' -o tsv
  az ad group list --filter "displayName eq '$($app2AdminLoginGroup.name)'" --query '[].displayName' -o tsv
)
if ($existing) {
  Write-Host "Already in Entra ID, nothing created: $($existing -join ', ')"
  return
}

# Create Test User (must change the password at first sign-in)
$password = Read-Host "One-time password for $($config.testUserUpn)"
$userId = az ad user create `
  --display-name "User 01" `
  --user-principal-name $config.testUserUpn `
  --password $password `
  --force-change-password-next-sign-in true `
  --query id -o tsv

# Create Groups
$bastionUsersGroup.objectId = az ad group create --display-name $bastionUsersGroup.name --mail-nickname $bastionUsersGroup.name --query id -o tsv
$app1AdminLoginGroup.objectId = az ad group create --display-name $app1AdminLoginGroup.name --mail-nickname $app1AdminLoginGroup.name --query id -o tsv
$app2AdminLoginGroup.objectId = az ad group create --display-name $app2AdminLoginGroup.name --mail-nickname $app2AdminLoginGroup.name --query id -o tsv

# Assign Memberships
az ad group member add --group $bastionUsersGroup.objectId --member-id $userId
az ad group member add --group $app1AdminLoginGroup.objectId --member-id $userId
az ad group member add --group $app2AdminLoginGroup.objectId --member-id $userId

# Save Group IDs back to the config file
$config | ConvertTo-Json -Depth 10 | Set-Content config/platform.json

# Check the test user's groups
# az ad user get-member-groups --id $userId -o table

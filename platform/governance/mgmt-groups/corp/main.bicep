/*
Governance for the Corp management group (ALZ landingzones/corp): landing zones that connect to the hub and must
not be reachable from, or go to, the internet directly. Owned by the platform team. Deploy at management group scope:
  az deployment mg create -n governance-corp -m <corp-mg-id> -l swedencentral -f platform/governance/mgmt-groups/corp/main.bicep -p platform/governance/mgmt-groups/corp/main.bicepparam
Only for the Corp MG: the connectivity subscription needs public IPs (firewall, Bastion) and must not be under it.
Deny doesn't touch existing resources; they show up as non-compliant (az policy state trigger-scan).
*/

targetScope = 'managementGroup'

@description('Location of the policy assignment metadata')
param location string = deployment().location

@description('Default enforces the Deny effects; DoNotEnforce only reports compliance, for a first dry run')
@allowed([
  'Default'
  'DoNotEnforce'
])
param enforcementMode string = 'Default'

// -------------------- CUSTOM POLICY DEFINITIONS --------------------
// Deny-Subnet-Without-Udr is an ALZ custom definition, not built-in. The JSON is copied unchanged from the ALZ library
// (Azure/Azure-Landing-Zones-Library, platform/alz/policy_definitions); update it by replacing the file.
// Defined on the Corp MG, so it can be assigned only here and below. ALZ defines it on the intermediate root MG;
// move it there once the full hierarchy exists. No AVM module for policy definitions, so it's a plain resource.
var denySubnetWithoutUdrDefinition = loadJsonContent('policy-definitions/Deny-Subnet-Without-Udr.alz_policy_definition.json')

resource denySubnetWithoutUdr 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: denySubnetWithoutUdrDefinition.name
  properties: denySubnetWithoutUdrDefinition.properties
}

// -------------------- POLICY ASSIGNMENTS (AVM) --------------------
// ALZ assignment names (max 24 characters at management group scope). Deny effects need no managed identity.

// No public IP resources in Corp subscriptions at all (also rules out public load balancers, NAT gateways, VPN gateways)
module denyPublicIp 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'Deny-Public-IP'
  params: {
    name: 'Deny-Public-IP'
    displayName: 'Deny the creation of public IP'
    description: 'Corp landing zones reach the internet only through the hub firewall, so public IP addresses are not allowed.'
    // Built-in: Not allowed resource types
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '6c112d4e-5bc7-47ae-a041-ea2d9dccd749')
    parameters: {
      listOfResourceTypesNotAllowed: {
        value: [
          'microsoft.network/publicipaddresses'
        ]
      }
    }
    nonComplianceMessages: [
      {
        message: 'Public IP addresses are not allowed in Corp landing zones. Internet traffic goes through the hub firewall.'
      }
    ]
    identity: 'None'
    enforcementMode: enforcementMode
    location: location
    enableTelemetry: false
  }
}

// Second layer: no NIC may reference a public IP, even one that exists elsewhere or is exempted from Deny-Public-IP
module denyPublicIpOnNic 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'Deny-Public-IP-On-NIC'
  params: {
    name: 'Deny-Public-IP-On-NIC'
    displayName: 'Deny network interfaces having a public IP'
    description: 'Network interfaces in Corp landing zones must not have a public IP address.'
    // Built-in: Network interfaces should not have public IPs
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '83a86a26-fd1f-447c-b59d-e51f44264114')
    nonComplianceMessages: [
      {
        message: 'Network interfaces in Corp landing zones must not have a public IP address.'
      }
    ]
    identity: 'None'
    enforcementMode: enforcementMode
    location: location
    enableTelemetry: false
  }
}

// Every subnet needs a route table, i.e. the 0.0.0.0/0 route to the hub firewall (forced egress).
// Excludes AzureBastionSubnet and RouteServerSubnet (definition default). It checks that a route table exists,
// not its routes. Works with landing-zones/main.bicep: AVM creates the VNet first and the subnets (with their
// route table) as separate child resources.
module denySubnetWithoutUdrAssignment 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'Deny-Subnet-Without-Udr'
  params: {
    name: 'Deny-Subnet-Without-Udr'
    displayName: denySubnetWithoutUdrDefinition.properties.displayName
    description: 'Corp landing zone subnets must route through the hub firewall, so every subnet needs a route table.'
    policyDefinitionId: denySubnetWithoutUdr.id
    nonComplianceMessages: [
      {
        message: 'Subnets in Corp landing zones must have a route table (0.0.0.0/0 to the hub firewall).'
      }
    ]
    identity: 'None'
    enforcementMode: enforcementMode
    location: location
    enableTelemetry: false
  }
}

output policyAssignmentIds string[] = [
  denyPublicIp.outputs.resourceId
  denyPublicIpOnNic.outputs.resourceId
  denySubnetWithoutUdrAssignment.outputs.resourceId
]
output denySubnetWithoutUdrDefinitionId string = denySubnetWithoutUdr.id

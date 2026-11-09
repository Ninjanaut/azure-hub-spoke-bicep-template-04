using 'main.bicep'

// enforcementMode turns the policies' effect on or off. All three Corp policies have the effect Deny.
//   'Default'      = enforce (the default)
//   'DoNotEnforce' = report only, block nothing (for a first rollout)
//
// Effect (in the policy definition) + enforcementMode -> creating a public IP in a spoke:
//   Deny  + Default        -> blocked (RequestDisallowedByPolicy), reported as non-compliant
//   Deny  + DoNotEnforce   -> created, reported as non-compliant
//   Audit + either         -> created, reported as non-compliant
// Existing resources are never changed or deleted.
param enforcementMode = 'Default'

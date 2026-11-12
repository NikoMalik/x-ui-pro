#!/bin/bash
[[ $EUID -ne 0 ]] && echo "Run as root: sudo bash $0 -subdomain new.panel.tld [-reality_domain new.reality.tld]" && exit 1
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}

XUIDB="${XUIDB:-/etc/x-ui/x-ui.db}"
NGX="${NGX:-/etc/nginx}"
LE="${LE:-/etc/letsencrypt/live}"
RCERT="${RCERT:-/root/cert}"
SUBPAGE="${SUBPAGE:-/var/www/subpage}"
BKROOT="${BKROOT:-/root}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
STREAM="$NGX/stream-enabled/stream.conf"
new=""
old=""
new_r=""
old_r=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -subdomain) new="$2"; shift 2;;
    -old_domain) old="$2"; shift 2;;
    -reality_domain) new_r="$2"; shift 2;;
    -old_reality) old_r="$2"; shift 2;;
    *) shift 1;;
  esac
done

if [[ -z "$new" && -z "$new_r" ]]; then
	echo -en "NEW panel subdomain (empty = keep current): " && read new
	echo -en "NEW REALITY subdomain (empty = keep current): " && read new_r
fi
new=$(echo "$new" | tr -d '[:space:]')
new_r=$(echo "$new_r" | tr -d '[:space:]')
[[ -n "$new" || -n "$new_r" ]] || { msg_err "Nothing to change"; exit 1; }
for d in "$new" "$new_r"; do
	[[ -z "$d" || "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { msg_err "Bad domain: $d"; exit 1; }
done
[[ -f "$XUIDB" ]] || { msg_err "$XUIDB not found"; exit 1; }
command -v sqlite3 &>/dev/null || apt-get install -y -q sqlite3

if [[ -z "$old" ]]; then
	web_cert=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webCertFile';")
	[[ "$web_cert" =~ ^$RCERT/([^/]+)/ ]] && old="${BASH_REMATCH[1]}"
fi
for f in "$NGX"/sites-available/*; do
	[[ -f "$f" ]] || continue
	if grep -q 'listen 7443' "$f"; then
		[[ -z "$old" ]] && old=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
	elif grep -q 'listen 9443' "$f"; then
		[[ -z "$old_r" ]] && old_r=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
	fi
done
[[ -n "$old" ]] || { msg_err "Cannot detect panel domain, pass -old_domain"; exit 1; }
[[ -n "$old_r" ]] || { msg_err "Cannot detect REALITY domain, pass -old_reality"; exit 1; }
[[ -f "$NGX/sites-available/$old" ]] || { msg_err "$NGX/sites-available/$old not found"; exit 1; }
[[ -f "$NGX/sites-available/$old_r" ]] || { msg_err "$NGX/sites-available/$old_r not found"; exit 1; }

panel="${new:-$old}"
reality="${new_r:-$old_r}"
[[ -z "$new" || "$new" != "$old" ]] || { msg_err "New panel domain is the same as old: $old"; exit 1; }
[[ -z "$new_r" || "$new_r" != "$old_r" ]] || { msg_err "New REALITY domain is the same as old: $old_r"; exit 1; }
[[ "$panel" != "$reality" ]] || { msg_err "Panel and REALITY domains must differ"; exit 1; }
[[ -z "$new" || "$new" != "$old_r" ]] || { msg_err "New panel domain is the current REALITY domain"; exit 1; }
[[ -z "$new_r" || "$new_r" != "$old" ]] || { msg_err "New REALITY domain is the current panel domain"; exit 1; }

is_cf() {
	[[ "$1" =~ ^(104\.(1[6-9]|2[0-7])\.|131\.0\.7[2-5]\.|172\.(6[4-9]|7[01])\.|188\.114\.(9[6-9]|10[0-9]|11[01])\.|162\.15[89]\.|141\.101\.|108\.162\.|190\.93\.|197\.234\.|198\.41\.|173\.245\.|103\.(21|22|31)\.) ]]
}

IP4="${IP4:-$(curl -s4 --max-time 10 ipv4.icanhazip.com | tr -d '[:space:]')}"
[[ "$IP4" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg_err "Cannot get public IPv4"; exit 1; }
if [[ -n "$new" ]]; then
	resolved=$(getent ahostsv4 "$new" | awk 'NR==1{print $1}')
	if [[ "$resolved" != "$IP4" ]]; then
		if is_cf "$resolved"; then
			msg_inf "$new is behind Cloudflare ($resolved), cert check goes through Cloudflare, Always Use HTTPS must be off"
		else
			msg_err "$new resolves to '${resolved}', not $IP4. Add DNS A record first"; exit 1
		fi
	fi
fi
if [[ -n "$new_r" ]]; then
	resolved=$(getent ahostsv4 "$new_r" | awk 'NR==1{print $1}')
	is_cf "$resolved" && { msg_err "$new_r is behind Cloudflare ($resolved), REALITY domain must be grey cloud (DNS only)"; exit 1; }
	[[ "$resolved" == "$IP4" ]] || { msg_err "$new_r resolves to '${resolved}', not $IP4. Add DNS A record first"; exit 1; }
fi

msg_inf "panel domain:   $old -> $panel"
msg_inf "reality domain: $old_r -> $reality"
msg_inf "server IP:      $IP4"

bk="$BKROOT/patch_old_backup_$(date +%F_%H%M%S)"
mkdir -p "$bk"
cp -a "$NGX" "$bk/nginx"
cp -a "$XUIDB" "$bk/x-ui.db"
[[ -d "$SUBPAGE" ]] && cp -a "$SUBPAGE" "$bk/subpage"
crontab -l > "$bk/crontab" 2>/dev/null
msg_ok "Backup: $bk"

systemctl stop nginx
fuser -k 80/tcp 2>/dev/null
for d in $new $new_r; do
	certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$d"
done
systemctl start nginx
for d in $new $new_r; do
	[[ -f "$LE/$d/fullchain.pem" ]] || { msg_err "SSL for $d failed, nothing changed"; exit 1; }
done

replace_domain() {
	local from="$1" to="$2"
	shift 2
	OLD="$from" NEW="$to" perl -pi -e 's/(?<![\w.-])\Q$ENV{OLD}\E(?![\w-])/$ENV{NEW}/g' "$@"
}

move_vhost() {
	replace_domain "$1" "$2" "$STREAM" "$NGX/sites-available/80.conf" "$NGX/sites-available/$1"
	mv "$NGX/sites-available/$1" "$NGX/sites-available/$2"
	rm -f "$NGX/sites-enabled/$1"
	ln -sf "$NGX/sites-available/$2" "$NGX/sites-enabled/"
}

if [[ -n "$new" ]]; then
	mkdir -p "$RCERT/$new"
	chmod 755 "$RCERT"/*
	ln -sf "$LE/$new/fullchain.pem" "$RCERT/$new/fullchain.pem"
	ln -sf "$LE/$new/privkey.pem" "$RCERT/$new/privkey.pem"
	move_vhost "$old" "$new"
fi
[[ -n "$new_r" ]] && move_vhost "$old_r" "$new_r"
grep -q proxy_timeout "$STREAM" || sed -i '/ssl_preread/a\    proxy_timeout 1h;' "$STREAM"

if ! nginx -t; then
	msg_err "nginx config failed, restoring backup"
	rm -rf "$NGX" && cp -a "$bk/nginx" "$NGX"
	systemctl restart nginx
	exit 1
fi
systemctl reload nginx

has_hosts=$(sqlite3 "$XUIDB" "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts';")
systemctl stop x-ui
if [[ -n "$new" ]]; then
	sqlite3 "$XUIDB" <<EOF
UPDATE settings SET value = replace(value, '${old}', '${new}') WHERE key IN ('subURI','subJsonURI','webDomain','subDomain');
UPDATE inbounds SET stream_settings = replace(stream_settings, '"${old}"', '"${new}"');
EOF
	[[ -n "$has_hosts" ]] && sqlite3 "$XUIDB" "UPDATE hosts SET address = '${new}' WHERE address = '${old}'; UPDATE hosts SET sni = '${new}' WHERE sni = '${old}';"
fi
if [[ -n "$new_r" ]]; then
	sqlite3 "$XUIDB" <<EOF
UPDATE inbounds SET stream_settings = replace(replace(stream_settings, '"${old_r}"', '"${new_r}"'), '/live/${old_r}/', '/live/${new_r}/');
EOF
	[[ -n "$has_hosts" ]] && sqlite3 "$XUIDB" "UPDATE hosts SET sni = '${new_r}' WHERE sni = '${old_r}';"
fi
sqlite3 "$XUIDB" <<EOF
UPDATE inbounds SET stream_settings = json_set(stream_settings, '$.externalProxy[0].dest', '${IP4}')
	WHERE json_extract(stream_settings, '$.security') = 'reality'
	AND json_extract(stream_settings, '$.externalProxy[0].dest') IS NOT NULL;
UPDATE inbounds SET stream_settings = json_set(stream_settings, '$.realitySettings.settings.fingerprint', 'chrome')
	WHERE json_extract(stream_settings, '$.security') = 'reality';
EOF
[[ -n "$has_hosts" ]] && sqlite3 "$XUIDB" "UPDATE hosts SET address = '${IP4}'
	WHERE coalesce(remark, '') NOT LIKE '%-relay' AND coalesce(remark, '') NOT LIKE '%-cfip'
	AND inbound_id IN (SELECT id FROM inbounds WHERE json_extract(stream_settings, '\$.security') = 'reality');"
[[ -n "$new" && -x "$XUI_BIN" ]] && "$XUI_BIN" cert -webCert "$RCERT/$new/fullchain.pem" -webCertKey "$RCERT/$new/privkey.pem"
systemctl start x-ui

if [[ -n "$new" ]]; then
	for f in "$SUBPAGE/index.html" "$SUBPAGE/clash.yaml" "$SUBPAGE/clash.yaml.tpl"; do
		[[ -f "$f" ]] && replace_domain "$old" "$new" "$f"
	done
fi

(crontab -l 2>/dev/null | grep -v certbot; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -

for d in $([[ -n "$new" ]] && echo "$old") $([[ -n "$new_r" ]] && echo "$old_r"); do
	left=$(grep -rlP "(?<![\w.-])${d//./\\.}(?![\w-])" "$NGX/sites-enabled/" "$NGX/stream-enabled/" 2>/dev/null)
	[[ -n "$left" ]] && msg_err "Old domain $d still found in: $left"
done

panel_path=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webBasePath';" | sed 's|^/||;s|/$||')
sub_uri=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subURI';")

if systemctl is-active --quiet x-ui; then
	msg_ok "Done"
else
	msg_err "x-ui is not running, check: x-ui log"
fi
msg_inf "Panel:         https://${panel}/${panel_path}/"
msg_inf "REALITY SNI:   ${reality}"
msg_inf "Subscription:  ${sub_uri}<subId>"
msg_inf "Clients must re-import or update the subscription"
msg_inf "Backup:        $bk"

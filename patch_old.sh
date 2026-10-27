#!/bin/bash
[[ $EUID -ne 0 ]] && echo "Run as root: sudo bash $0 -subdomain new.domain.tld" && exit 1
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}

XUIDB="/etc/x-ui/x-ui.db"
STREAM="/etc/nginx/stream-enabled/stream.conf"
new=""
old=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -subdomain) new="$2"; shift 2;;
    -old_domain) old="$2"; shift 2;;
    *) shift 1;;
  esac
done

while [[ -z "$new" ]]; do
	echo -en "Enter NEW subdomain for panel (sub.domain.tld): " && read new
done
new=$(echo "$new" | tr -d '[:space:]')
[[ "$new" =~ ^[A-Za-z0-9.-]+$ ]] || { msg_err "Bad domain: $new"; exit 1; }
[[ -f "$XUIDB" ]] || { msg_err "$XUIDB not found"; exit 1; }
command -v sqlite3 &>/dev/null || apt-get install -y -q sqlite3

if [[ -z "$old" ]]; then
	web_cert=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webCertFile';")
	[[ "$web_cert" =~ ^/root/cert/([^/]+)/ ]] && old="${BASH_REMATCH[1]}"
fi
reality_domain=""
for f in /etc/nginx/sites-available/*; do
	[[ -f "$f" ]] || continue
	if grep -q 'listen 7443' "$f"; then
		[[ -z "$old" ]] && old=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
	elif grep -q 'listen 9443' "$f"; then
		reality_domain=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
	fi
done
[[ -n "$old" ]] || { msg_err "Cannot detect old panel domain, pass -old_domain"; exit 1; }
[[ -f "/etc/nginx/sites-available/${old}" ]] || { msg_err "/etc/nginx/sites-available/${old} not found"; exit 1; }
[[ "$new" != "$old" ]] || { msg_err "New domain is the same as old: $old"; exit 1; }
[[ "$new" != "$reality_domain" ]] || { msg_err "New domain must differ from REALITY domain"; exit 1; }

IP4=$(curl -s4 --max-time 10 ipv4.icanhazip.com | tr -d '[:space:]')
[[ "$IP4" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg_err "Cannot get public IPv4"; exit 1; }
resolved=$(getent ahostsv4 "$new" | awk 'NR==1{print $1}')
[[ "$resolved" == "$IP4" ]] || { msg_err "$new resolves to '${resolved}', not $IP4. Add DNS A record first"; exit 1; }

msg_inf "old domain:     $old"
msg_inf "new domain:     $new"
msg_inf "reality domain: $reality_domain"
msg_inf "server IP:      $IP4"

bk="/root/patch_old_backup_$(date +%F_%H%M%S)"
mkdir -p "$bk"
cp -a /etc/nginx "$bk/nginx"
cp -a "$XUIDB" "$bk/x-ui.db"
[[ -d /var/www/subpage ]] && cp -a /var/www/subpage "$bk/subpage"
crontab -l > "$bk/crontab" 2>/dev/null
msg_ok "Backup: $bk"

systemctl stop nginx
fuser -k 80/tcp 2>/dev/null
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$new"
systemctl start nginx
[[ -f "/etc/letsencrypt/live/${new}/fullchain.pem" ]] || { msg_err "SSL for $new failed, nothing changed"; exit 1; }

mkdir -p "/root/cert/${new}"
chmod 755 /root/cert/*
ln -sf "/etc/letsencrypt/live/${new}/fullchain.pem" "/root/cert/${new}/fullchain.pem"
ln -sf "/etc/letsencrypt/live/${new}/privkey.pem" "/root/cert/${new}/privkey.pem"

replace_domain() {
	OLD="$old" NEW="$new" perl -pi -e 's/(?<![\w.-])\Q$ENV{OLD}\E(?![\w-])/$ENV{NEW}/g' "$@"
}

replace_domain "$STREAM" /etc/nginx/sites-available/80.conf "/etc/nginx/sites-available/${old}"
mv "/etc/nginx/sites-available/${old}" "/etc/nginx/sites-available/${new}"
rm -f "/etc/nginx/sites-enabled/${old}"
ln -sf "/etc/nginx/sites-available/${new}" /etc/nginx/sites-enabled/
grep -q proxy_timeout "$STREAM" || sed -i '/ssl_preread/a\    proxy_timeout 1h;' "$STREAM"

if ! nginx -t; then
	msg_err "nginx config failed, restoring backup"
	rm -rf /etc/nginx && cp -a "$bk/nginx" /etc/nginx
	systemctl restart nginx
	exit 1
fi
systemctl reload nginx

systemctl stop x-ui
sqlite3 "$XUIDB" <<EOF
UPDATE settings SET value = replace(value, '${old}', '${new}') WHERE key IN ('subURI','subJsonURI','webDomain','subDomain');
UPDATE inbounds SET stream_settings = replace(stream_settings, '"${old}"', '"${new}"');
UPDATE inbounds SET stream_settings = json_set(stream_settings, '$.externalProxy[0].dest', '${IP4}')
	WHERE json_extract(stream_settings, '$.security') = 'reality'
	AND json_extract(stream_settings, '$.externalProxy[0].dest') IS NOT NULL;
UPDATE inbounds SET stream_settings = json_set(stream_settings, '$.realitySettings.settings.fingerprint', 'chrome')
	WHERE json_extract(stream_settings, '$.security') = 'reality';
EOF
if sqlite3 "$XUIDB" "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts';" | grep -q hosts; then
	sqlite3 "$XUIDB" <<EOF
UPDATE hosts SET address = '${new}' WHERE address = '${old}';
UPDATE hosts SET address = '${IP4}'
	WHERE inbound_id IN (SELECT id FROM inbounds WHERE json_extract(stream_settings, '$.security') = 'reality');
EOF
fi
/usr/local/x-ui/x-ui cert -webCert "/root/cert/${new}/fullchain.pem" -webCertKey "/root/cert/${new}/privkey.pem"
systemctl start x-ui

for f in /var/www/subpage/index.html /var/www/subpage/clash.yaml; do
	[[ -f "$f" ]] && replace_domain "$f"
done

(crontab -l 2>/dev/null | grep -v certbot; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -

left=$(grep -rlP "(?<![\w.-])${old//./\\.}(?![\w-])" /etc/nginx/sites-enabled/ /etc/nginx/stream-enabled/ 2>/dev/null)
[[ -n "$left" ]] && msg_err "Old domain still found in: $left"

panel_path=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webBasePath';" | sed 's|^/||;s|/$||')
sub_uri=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subURI';")

if systemctl is-active --quiet x-ui; then
	msg_ok "Done"
else
	msg_err "x-ui is not running, check: x-ui log"
fi
msg_inf "Panel:         https://${new}/${panel_path}/"
msg_inf "Subscription:  ${sub_uri}<subId>"
msg_inf "Clients must re-import subscription with the new domain"
msg_inf "Backup:        $bk"

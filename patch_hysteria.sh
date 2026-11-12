#!/bin/bash
[[ $EUID -ne 0 ]] && echo "Run as root: sudo bash $0" && exit 1
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}

XUIDB="${XUIDB:-/etc/x-ui/x-ui.db}"
NGINX_SITES="${NGINX_SITES:-/etc/nginx/sites-available}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
email="firstH"
port=443
sub_id=""
reality_domain=""
IP4="${IP4:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -email) email="$2"; shift 2;;
    -port) port="$2"; shift 2;;
    -subid) sub_id="$2"; shift 2;;
    -reality_domain) reality_domain="$2"; shift 2;;
    *) shift 1;;
  esac
done

gen_random_string() {
	head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$1"
	echo
}

db() { sqlite3 "$XUIDB" "$@"; }

[[ -f "$XUIDB" ]] || { msg_err "$XUIDB not found"; exit 1; }
[[ "$email" =~ ^[A-Za-z0-9_.@-]+$ ]] || { msg_err "Bad email: $email"; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { msg_err "Bad port: $port"; exit 1; }

if [[ -z "$reality_domain" ]]; then
	for f in "$NGINX_SITES"/*; do
		[[ -f "$f" ]] && grep -q 'listen 9443' "$f" && reality_domain=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
	done
fi
[[ -n "$reality_domain" ]] || { msg_err "Cannot detect REALITY domain, pass -reality_domain"; exit 1; }
[[ -f "$LE_LIVE/$reality_domain/fullchain.pem" ]] || { msg_err "No cert at $LE_LIVE/$reality_domain"; exit 1; }

[[ -n "$IP4" ]] || IP4=$(curl -s4 --max-time 10 ipv4.icanhazip.com | tr -d '[:space:]')
[[ "$IP4" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg_err "Cannot get public IPv4"; exit 1; }

if [[ -z "$sub_id" ]]; then
	sub_id=$(db "SELECT json_extract(value, '\$.subId') FROM inbounds, json_each(inbounds.settings, '\$.clients') WHERE json_extract(value, '\$.subId') <> '' LIMIT 1;")
	sub_id="${sub_id:-first}"
fi

hy_id=$(db "SELECT id FROM inbounds WHERE protocol='hysteria' ORDER BY id LIMIT 1;")
if [[ -z "$hy_id" ]] && db "SELECT 1 FROM inbounds WHERE port=$port AND json_extract(stream_settings,'\$.network')='hysteria';" | grep -q 1; then
	msg_err "UDP port $port is already used by another inbound"; exit 1
fi

cert="$LE_LIVE/$reality_domain/fullchain.pem"
key="$LE_LIVE/$reality_domain/privkey.pem"
hy_obfs=$(gen_random_string 16)
hy_auth=$(gen_random_string 16)
client_json="{\"email\":\"$email\",\"auth\":\"$hy_auth\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"subId\":\"$sub_id\",\"reset\":0}"
sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

msg_inf "reality domain: $reality_domain"
msg_inf "server IP:      $IP4"
msg_inf "subId:          $sub_id"

bk="/root/patch_hysteria_backup_$(date +%F_%H%M%S).db"
cp -a "$XUIDB" "$bk"
msg_ok "Backup: $bk"

systemctl stop x-ui 2>/dev/null

if [[ -z "$hy_id" ]]; then
	db "SELECT 1 FROM client_traffics WHERE email='$email';" | grep -q 1 && { msg_err "Client $email already exists, pass -email"; systemctl start x-ui; exit 1; }
	db <<EOF
INSERT INTO inbounds ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES ('1','0','0','0','hysteria2','1','0','','$port','hysteria',
	json('{"version":2,"clients":[$client_json]}'),
	json('{"network":"hysteria","security":"tls","hysteriaSettings":{"version":2},"tlsSettings":{"serverName":"$reality_domain","alpn":["h3"],"certificates":[{"certificateFile":"$cert","keyFile":"$key"}]},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"$hy_obfs"}}]},"externalProxy":[{"forceTls":"same","dest":"$IP4","port":$port,"remark":""}]}'),
	'inbound-$port-udp',
	json('$sniffing'));
INSERT INTO client_traffics ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES (last_insert_rowid(),'1','$email','0','0','0','0','0');
EOF
	hy_id=$(db "SELECT id FROM inbounds WHERE protocol='hysteria' ORDER BY id LIMIT 1;")
	msg_ok "Hysteria2 inbound created (id $hy_id)"
else
	db <<EOF
UPDATE inbounds SET stream_settings = json_set(stream_settings,
	'\$.network', 'hysteria',
	'\$.security', 'tls',
	'\$.hysteriaSettings.version', 2,
	'\$.tlsSettings.serverName', '$reality_domain',
	'\$.tlsSettings.alpn', json('["h3"]'),
	'\$.tlsSettings.certificates', json('[{"certificateFile":"$cert","keyFile":"$key"}]'),
	'\$.externalProxy', json('[{"forceTls":"same","dest":"$IP4","port":' || port || ',"remark":""}]')),
	sniffing = json('$sniffing')
WHERE id = $hy_id;
UPDATE inbounds SET stream_settings = json_set(stream_settings, '\$.finalmask', json('{"udp":[{"type":"salamander","settings":{"password":"$hy_obfs"}}]}'))
WHERE id = $hy_id AND coalesce(json_extract(stream_settings, '\$.finalmask.udp[0].type'), '') <> 'salamander';
EOF
	if [[ "$(db "SELECT coalesce(json_array_length(settings, '\$.clients'), 0) FROM inbounds WHERE id = $hy_id;")" == "0" ]]; then
		db "SELECT 1 FROM client_traffics WHERE email='$email';" | grep -q 1 && { msg_err "Inbound has no clients and $email already exists, pass -email"; systemctl start x-ui; exit 1; }
		db <<EOF
UPDATE inbounds SET settings = json_set(coalesce(nullif(settings, ''), '{}'), '\$.version', 2, '\$.clients', json('[$client_json]')) WHERE id = $hy_id;
INSERT INTO client_traffics ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ($hy_id,'1','$email','0','0','0','0','0');
EOF
		msg_ok "Client $email added"
	fi
	msg_ok "Hysteria2 inbound $hy_id updated, clients kept"
fi

if db "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts';" | grep -q hosts; then
	db "UPDATE hosts SET address = '$IP4' WHERE inbound_id = $hy_id;"
fi
db "DELETE FROM history_of_seeders WHERE seeder_name='ClientsTable';" 2>/dev/null

command -v ufw &>/dev/null && ufw allow "$port"/udp >/dev/null

systemctl start x-ui
sleep 3
if systemctl is-active --quiet x-ui; then
	msg_ok "Done"
else
	msg_err "x-ui did not start, restore: systemctl stop x-ui; cp $bk $XUIDB; systemctl start x-ui"
	exit 1
fi
port_now=$(db "SELECT port FROM inbounds WHERE id = $hy_id;")
msg_inf "Hysteria2: udp $IP4:$port_now, sni $reality_domain, salamander obfs"
msg_inf "Clients re-import the subscription to get the link"
msg_inf "Backup: $bk"

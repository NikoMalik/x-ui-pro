#!/bin/bash
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

XUIDB="/etc/x-ui/x-ui.db"
XCONF="/usr/local/x-ui/bin/config.json"
AGH_YAML="/opt/AdGuardHome/AdGuardHome.yaml"
XRAY=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
SEEN="/var/lib/xui-tools/seen.tsv"

panel_tz() {
	local tz
	tz=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='timeLocation';" 2>/dev/null)
	echo "${tz:-UTC}"
}

api_online() {
	local port
	port=$(jq -r '.inbounds[] | select(.tag=="api") | .port' "$XCONF" 2>/dev/null)
	[[ -n "$XRAY" && -n "$port" ]] || return 1
	"$XRAY" api statsonlineiplist -s "127.0.0.1:${port}" -all "$@" 2>/dev/null
}

online_rows() {
	jq -r '.users[]? | .email as $e | .ips[]? | [$e, .ip, ((.lastSeen // .last_seen // 0) | tonumber)] | @tsv'
}

inbound_map() {
	local m
	m=$(sqlite3 -json "$XUIDB" "SELECT c.email, i.protocol, i.port FROM client_traffics c JOIN inbounds i ON i.id = c.inbound_id;" 2>/dev/null \
		| jq -c 'map({(.email): "\(.protocol):\(.port)"}) | add // {}' 2>/dev/null)
	echo "${m:-{\}}"
}

online_table() {
	TZ="$(panel_tz)" jq -Rr --argjson m "$(inbound_map)" --arg f "$1" '
		split("\t") | [.[0], ($m[.[0]] // "?"), .[1], (.[2] | tonumber | strflocaltime("%Y-%m-%d %H:%M:%S"))]
		| select($f == "" or (.[1] | test($f; "i")))
		| @tsv' \
	| column -t -s $'\t' -N EMAIL,INBOUND,IP,LAST_SEEN
}

cmd_online() {
	local json
	json=$(api_online) || { echo "xray binary or api port not found"; exit 1; }
	echo "time zone: $(panel_tz)"
	online_rows <<< "$json" | sort -t$'\t' -k3,3nr | online_table "$1"
}

merge_seen() {
	awk -F'\t' -v OFS='\t' -v st="$1" '
		BEGIN { while ((getline line < st) > 0) { split(line, a, "\t"); k = a[1] "\t" a[2]; f[k] = a[3]; l[k] = a[4] } }
		$3 > 0 { k = $1 "\t" $2; if (!(k in f) || $3 < f[k]) f[k] = $3; if ($3 > l[k]) l[k] = $3 }
		END { for (k in f) print k, f[k], l[k] }'
}

cmd_snapshot() {
	local json
	json=$(api_online) || exit 1
	mkdir -p "$(dirname "$SEEN")"
	touch "$SEEN"
	online_rows <<< "$json" | merge_seen "$SEEN" > "${SEEN}.tmp" && mv "${SEEN}.tmp" "$SEEN"
}

cmd_history() {
	[[ -s "$SEEN" ]] || { echo "no history yet, enable it: see 'xui-tools' usage"; exit 1; }
	echo "time zone: $(panel_tz)"
	sort -t$'\t' -k4,4nr "$SEEN" \
	| TZ="$(panel_tz)" jq -Rr 'split("\t") | [.[0], .[1],
		(.[2] | tonumber | strflocaltime("%Y-%m-%d %H:%M")),
		(.[3] | tonumber | strflocaltime("%Y-%m-%d %H:%M"))] | @tsv' \
	| column -t -s $'\t' -N EMAIL,IP,FIRST_SEEN,LAST_SEEN
}

clients_table() {
	TZ="$(panel_tz)" jq -r --argjson online "$1" '
		def secs: if . > 100000000000 then . / 1000 | floor else . end;
		def when: if . > 0 then secs | strflocaltime("%Y-%m-%d %H:%M") else "never" end;
		def size: if . >= 1073741824 then "\(. / 1073741824 * 100 | round / 100)G"
			elif . >= 1048576 then "\(. / 1048576 | round)M" else "\(. / 1024 | round)K" end;
		def ips: (.ips // "") | (if type == "string" then (fromjson? // []) else . end)
			| (if type == "string" then (fromjson? // []) else . end)
			| if type == "array" then sort_by(-(.timestamp // 0)) | map("\(.ip) \((.timestamp // 0) | when)") | join(", ") else "" end;
		.[] | .email as $e | [
			$e,
			(if $online == null then "?" elif ($online | index([$e])) then "ONLINE" else "off" end),
			(if .enable == 1 then "yes" else "no" end),
			((.last_online // 0) | when),
			((.up // 0) | size),
			((.down // 0) | size),
			ips
		] | @tsv' \
	| column -t -s $'\t' -N EMAIL,STATUS,ENABLED,LAST_ONLINE,UP,DOWN,IPS
}

cmd_clients() {
	local online
	online=$(api_online | jq -c '[.users[]?.email]' 2>/dev/null)
	[[ -n "$online" ]] || online="null"
	echo "time zone: $(panel_tz)"
	sqlite3 -json "$XUIDB" "SELECT c.email, c.enable, c.up, c.down, c.last_online, ip.ips
		FROM client_traffics c LEFT JOIN inbound_client_ips ip ON ip.client_email = c.email
		ORDER BY c.last_online DESC;" | clients_table "$online"
}

cmd_conns() {
	ss -Htn state established '( sport = :443 )' \
		| awk '{print $4}' | sed 's/:[^:]*$//; s/^\[//; s/\]$//; s/^::ffff://' \
		| sort | uniq -c | sort -rn | awk '{printf "%6d  %s\n", $1, $2}'
}

cmd_top() {
	local j1 j2 iv=2
	j1=$(api_online -include-traffic) || { echo "xray binary or api port not found"; exit 1; }
	sleep "$iv"
	j2=$(api_online -include-traffic)
	{ jq -r '.users[]? | ["1", .email, (.traffic.uplink // 0), (.traffic.downlink // 0)] | @tsv' <<< "$j1"
	  jq -r '.users[]? | ["2", .email, (.traffic.uplink // 0), (.traffic.downlink // 0)] | @tsv' <<< "$j2"; } \
	| awk -F'\t' -v OFS='\t' -v iv="$iv" '
		function hs(b,  u){ u="B/s"; if(b>=1073741824){b/=1073741824;u="GB/s"} else if(b>=1048576){b/=1048576;u="MB/s"} else if(b>=1024){b/=1024;u="KB/s"}; return sprintf("%.1f %s", b, u) }
		$1=="1"{ u1[$2]=$3; d1[$2]=$4 }
		$1=="2"{ u2[$2]=$3; d2[$2]=$4; seen[$2]=1 }
		END{ for(e in seen){ du=(u2[e]-u1[e])/iv; dd=(d2[e]-d1[e])/iv; if(du<0)du=0; if(dd<0)dd=0; print (du+dd), e, hs(dd), hs(du) } }' \
	| sort -t$'\t' -k1,1nr | cut -f2- \
	| column -t -s $'\t' -N EMAIL,DOWN,UP
}

cmd_traffic() {
	echo "time zone: $(panel_tz)"
	sqlite3 -json "$XUIDB" "SELECT email, up, down FROM client_traffics ORDER BY up+down DESC;" \
	| jq -r '
		def size: if . >= 1073741824 then "\(. / 1073741824 * 100 | round / 100)G"
			elif . >= 1048576 then "\(. / 1048576 | round)M"
			elif . >= 1024 then "\(. / 1024 | round)K" else "\(.)B" end;
		. as $all
		| ($all | map(.up) | add // 0) as $su
		| ($all | map(.down) | add // 0) as $sd
		| ($all[] | [.email, (.up | size), (.down | size), ((.up + .down) | size)]),
		  ["TOTAL", ($su | size), ($sd | size), (($su + $sd) | size)]
		| @tsv' \
	| column -t -s $'\t' -N EMAIL,UP,DOWN,TOTAL
}

cmd_backup() {
	local dir=/root/xui-backups ts out
	ts=$(date +%F_%H%M%S)
	out="$dir/xui-backup-${ts}.tar.gz"
	mkdir -p "$dir"
	tar czf "$out" --ignore-failed-read -P \
		/etc/x-ui/x-ui.db \
		/etc/nginx \
		/etc/letsencrypt \
		/opt/AdGuardHome/AdGuardHome.yaml \
		/var/lib/xui-tools/seen.tsv \
		/usr/local/bin/xui-tools 2>/dev/null
	ls -1t "$dir"/xui-backup-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
	echo "backup: $out ($(du -h "$out" | cut -f1))"
	echo "restore: systemctl stop x-ui nginx; tar xzf $out -P -C /; systemctl start x-ui nginx"
}

autoban_paths() {
	local inc=/etc/nginx/snippets/includes.conf
	{
		db_setting subPath
		db_setting subJsonPath
		db_setting webBasePath
		grep -A1 '#XHTTP' "$inc" 2>/dev/null | grep -oP 'location /\K[A-Za-z0-9]+'
		grep -oP 'location ~ \^/\K[A-Za-z0-9]+(?= \{)' "$inc" 2>/dev/null
		awk '/location \//{l=$2} /proxy_pass http:\/\/127\.0\.0\.1:8080\//{gsub("/", "", l); print l; exit}' "$inc" 2>/dev/null
	} | grep -E '^[A-Za-z0-9_-]+$' | sort -u | paste -sd'|'
}

cmd_autoban() {
	local cf paths ign
	case "$1" in
	on)
		command -v fail2ban-client &>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban
		cf="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 | xargs) $(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 | xargs)"
		[[ "$cf" == *"/"* ]] || { echo "cannot fetch Cloudflare ranges, not enabling, it could ban Cloudflare and cut every CDN client"; exit 1; }
		paths=$(autoban_paths)
		ign='\d+/'
		[[ -n "$paths" ]] && ign+="|(?:${paths})[/?\" ]"
		cat > /etc/fail2ban/filter.d/xui-scan.conf <<EOF
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]*\] "[A-Z]+ [^"]*" (?:404|444)
ignoreregex = ^\S+ \S+ \S+ \[[^\]]*\] "[A-Z]+ /(?:${ign})
EOF
		cat > /etc/fail2ban/jail.d/xui-scan.conf <<EOF
[xui-scan]
enabled = true
filter = xui-scan
logpath = /var/log/nginx/access.log
backend = auto
maxretry = ${XUI_AUTOBAN_HITS:-30}
findtime = 10m
bantime = ${XUI_AUTOBAN_TIME:-1d}
banaction = ufw
ignoreip = 127.0.0.1/8 ::1 $cf
EOF
		systemctl enable --now fail2ban >/dev/null 2>&1
		fail2ban-client reload >/dev/null && echo "autoban on: ${XUI_AUTOBAN_HITS:-30} hits of 404/444 in 10m -> ban ${XUI_AUTOBAN_TIME:-1d}"
		fail2ban-client status xui-scan
		;;
	off)
		rm -f /etc/fail2ban/jail.d/xui-scan.conf /etc/fail2ban/filter.d/xui-scan.conf
		fail2ban-client reload >/dev/null 2>&1
		echo "autoban off, already banned IPs stay in ufw until you unban them"
		;;
	test)
		fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/xui-scan.conf | sed -n '/^Lines:/p;/^Failregex:/p'
		;;
	*)
		command -v fail2ban-client &>/dev/null && fail2ban-client status xui-scan 2>/dev/null || echo "autoban is off, enable: xui-tools autoban on"
		;;
	esac
}

valid_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" == *:* ]]; }

cmd_ban() {
	valid_ip "$1" || { echo "usage: xui-tools ban <ip>"; exit 1; }
	[[ "$1" =~ ^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.)|^::1$|^::ffff:127\. ]] && { echo "refusing to ban local or private address $1, it would cut every client"; exit 1; }
	ufw insert 1 deny from "$1" 2>/dev/null || ufw deny from "$1"
	echo "banned $1"
}

cmd_unban() {
	valid_ip "$1" || { echo "usage: xui-tools unban <ip>"; exit 1; }
	ufw delete deny from "$1" && echo "unbanned $1"
}

cmd_watch() {
	trap 'exit 0' INT
	while :; do
		clear
		echo "$(date '+%Y-%m-%d %H:%M:%S')   $(uptime | sed 's/.*\(load.*\)/\1/')"
		echo
		cmd_online 2>/dev/null
		echo
		echo "top traffic now:"
		cmd_top 2>/dev/null | head -6
		sleep 3
	done
}

cmd_cert() {
	local force=""
	[[ "$1" == "force" ]] && force="--force-renewal"
	command -v certbot &>/dev/null || { echo "certbot not installed"; exit 1; }
	echo "nginx stops for a few seconds (VPN drops) ..."
	certbot renew $force --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
}

db_setting() {
	sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null | sed 's|^/||; s|/$||'
}

panel_domain() {
	db_setting webCertFile | sed -n 's|^root/cert/\([^/]*\)/.*|\1|p; s|^etc/letsencrypt/live/\([^/]*\)/.*|\1|p' | head -1
}

cmd_site() {
	local n="${1:-$(( RANDOM % 50 + 1 ))}" url tmp
	[[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 50 )) || { echo "usage: xui-tools site [1-50]"; exit 1; }
	url=$(printf "https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/assets/fake-sites/site-%02d/index.html" "$n")
	tmp=$(mktemp)
	curl -fsSL "$url" -o "$tmp" || { echo "download failed: $url"; rm -f "$tmp"; exit 1; }
	rm -rf /var/www/html.prev
	cp -a /var/www/html /var/www/html.prev
	find /var/www/html -mindepth 1 ! -name t.bin -delete
	install -m 644 -o www-data -g www-data "$tmp" /var/www/html/index.html
	rm -f "$tmp"
	echo "fake site: site-$(printf %02d "$n")"
	echo "undo: rm -rf /var/www/html && mv /var/www/html.prev /var/www/html"
}

cmd_subpage() {
	local v="${1:-0}" domain sp jp s2s wp tmp
	local urls=("https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui.html"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui-classical.html")
	[[ "$v" == 0 || "$v" == 1 ]] || { echo "usage: xui-tools subpage [0|1]"; exit 1; }
	domain=$(panel_domain)
	sp=$(db_setting subPath)
	jp=$(db_setting subJsonPath)
	[[ -n "$domain" && -n "$sp" ]] || { echo "cannot read domain or subPath from $XUIDB"; exit 1; }
	s2s=$(awk '/location \//{l=$2} /proxy_pass http:\/\/127\.0\.0\.1:8080\//{gsub("/", "", l); print l; exit}' /etc/nginx/snippets/includes.conf 2>/dev/null)
	wp=$(grep -oP 'location ~ \^/\K[A-Za-z0-9]+(?= \{)' /etc/nginx/snippets/includes.conf 2>/dev/null | head -1)
	tmp=$(mktemp)
	curl -fsSL "${urls[$v]}" -o "$tmp" || { echo "download failed: ${urls[$v]}"; rm -f "$tmp"; exit 1; }
	sed -i -e "s|\${DOMAIN}|$domain|g" -e "s|\${SUB_JSON_PATH}|$jp|g" -e "s|\${SUB_PATH}|$sp|g" "$tmp"
	[[ -n "$s2s" ]] && sed -i "s|sub\.legiz\.ru|$domain/$s2s|g" "$tmp"
	mkdir -p /var/www/subpage
	[[ -f /var/www/subpage/index.html ]] && cp -a /var/www/subpage/index.html /var/www/subpage/index.html.prev
	install -m 644 -o www-data -g www-data "$tmp" /var/www/subpage/index.html
	rm -f "$tmp"
	echo "sub page: template $v, domain $domain, sub_path $sp, json_path ${jp:--}, sub2sing-box ${s2s:--}"
	[[ -n "$wp" ]] && echo "open: https://$domain/$wp?name=first"
	echo "undo: mv /var/www/subpage/index.html.prev /var/www/subpage/index.html"
}

cmd_why() {
	local d="$1" e="$2" agh access
	[[ -n "$d" ]] || { echo "usage: xui-tools why <domain> [email]"; exit 1; }
	access=$(jq -r '.log.access // "none"' "$XCONF" 2>/dev/null)
	echo "== server -> https://$d"
	curl -s -o /dev/null --max-time 10 -w '  http %{http_code}, ip %{remote_ip}, %{time_total}s\n' "https://$d" || echo "  server cannot open https://$d"
	agh=$(awk '/^dns:/{f=1} f&&/^  port:/{print $2; exit}' "$AGH_YAML" 2>/dev/null)
	if [[ -n "$agh" ]] && command -v dig &>/dev/null; then
		echo "== AdGuard answer (0.0.0.0 means blocked)"
		echo "  $(dig @127.0.0.1 -p "$agh" "$d" +short | head -3 | xargs)"
	fi
	echo "== xray access log${e:+ for $e}"
	if [[ "$access" == "none" ]]; then
		echo "  access log is off, set \"access\" in Xray -> Advanced -> log, restart xray, repeat the test"
	else
		grep -F "$d" /var/log/x-ui/access.log 2>/dev/null | { [[ -n "$e" ]] && grep -F "email: $e" || cat; } | tail -n 10 | sed 's/^/  /'
	fi
	echo "== xray errors"
	grep -F "$d" /var/log/x-ui/3xui.log 2>/dev/null | grep -v X-Forwarded-For | tail -n 10 | sed 's/^/  /'
}

cmd_alias() {
	local act="$1" a="$2" pd vh bk map=/etc/nginx/stream-enabled/stream.conf r80=/etc/nginx/sites-available/80.conf sp
	[[ "$act" == add || "$act" == remove ]] || { echo "usage: xui-tools alias add|remove <extra.domain.tld>"; exit 1; }
	[[ "$a" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "bad domain: $a"; exit 1; }
	pd=$(panel_domain)
	vh="/etc/nginx/sites-available/$pd"
	[[ -n "$pd" && -f "$vh" ]] || { echo "panel vhost not found ($vh)"; exit 1; }
	[[ "$a" != "$pd" ]] || { echo "$a is already the panel domain"; exit 1; }
	bk="/root/xui-alias-backup-$(date +%F_%H%M%S)"
	cp -a /etc/nginx "$bk"
	if [[ "$act" == remove ]]; then
		rm -f "/etc/nginx/sites-available/$a" "/etc/nginx/sites-enabled/$a"
		sed -i "/^\s*${a//./\\.}\s\+www;/d" "$map"
		A=" $a" perl -pi -e 's/\Q$ENV{A}\E(?=[ ;])//' "$r80"
	else
		if [[ ! -f "/etc/letsencrypt/live/$a/fullchain.pem" ]]; then
			echo "issuing cert for $a, nginx stops for a few seconds (VPN drops)"
			systemctl stop nginx
			certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$a"
			systemctl start nginx
			[[ -f "/etc/letsencrypt/live/$a/fullchain.pem" ]] || { echo "cert for $a failed, check that $a points to this server or a relay that forwards port 80"; exit 1; }
		fi
		awk '/^server[ \t]*\{/{f=1} f' "$vh" \
			| OLD="$pd" NEW="$a" perl -pe 's/(?<![\w.-])\Q$ENV{OLD}\E(?![\w-])/$ENV{NEW}/g' > "/etc/nginx/sites-available/$a"
		ln -sf "/etc/nginx/sites-available/$a" /etc/nginx/sites-enabled/
		grep -qE "^\s*${a//./\\.}\s+www;" "$map" || sed -i "/^\s*default\s/i\    $a    www;" "$map"
		grep -qE "server_name[^;]*[[:space:]]${a//./\\.}[ ;]" "$r80" || sed -i "0,/server_name \([^;]*\);/s//server_name \1 $a;/" "$r80"
	fi
	if ! nginx -t; then
		echo "nginx config failed, restoring"
		rm -rf /etc/nginx && cp -a "$bk" /etc/nginx
		systemctl restart nginx
		exit 1
	fi
	systemctl reload nginx
	if [[ "$act" == add ]]; then
		sp=$(db_setting subPath)
		echo "alias $a -> same site, panel and subscription as $pd"
		echo "subscription: https://$a/${sp}/<subId>"
		echo "panel:        https://$a/$(db_setting webBasePath)/"
	else
		echo "alias $a removed, cert kept, delete it with: certbot delete --cert-name $a"
	fi
	echo "backup: $bk"
}

hosts_remove() {
	local n
	n=$(sqlite3 "$XUIDB" "DELETE FROM hosts WHERE address = '$1'; SELECT changes();" 2>/dev/null)
	echo "removed hosts: ${n:-0}"
	n=$(sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings, '\$.externalProxy',
			(SELECT json_group_array(json(value)) FROM json_each(inbounds.stream_settings, '\$.externalProxy')
			WHERE json_extract(value, '\$.dest') <> '$1'))
		WHERE json_type(stream_settings, '\$.externalProxy') = 'array' AND instr(stream_settings, '\"$1\"') > 0;
		SELECT changes();")
	echo "cleaned externalProxy in inbounds: $n"
}

hosts_show() {
	sqlite3 -header -column "$XUIDB" "SELECT h.id, i.remark AS inbound, h.remark, h.address, h.port, h.security, h.sni FROM hosts h JOIN inbounds i ON i.id = h.inbound_id ORDER BY h.inbound_id, h.id;" 2>/dev/null
}

cmd_relay() {
	local act="$1" ip="$2" bk sel col cols n is_dom
	[[ "$act" == add || "$act" == remove ]] || { echo "usage: xui-tools relay add|remove <relay-ip>"; exit 1; }
	[[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "bad IPv4: $ip"; exit 1; }
	bk="${XUIDB}.bak-relay-$(date +%F_%H%M%S)"
	cp -a "$XUIDB" "$bk"
	systemctl stop x-ui
	is_dom="address NOT LIKE '%:%' AND address GLOB '*[A-Za-z]*'"
	if [[ "$act" == remove ]]; then
		hosts_remove "$ip"
	elif [[ -n "$(sqlite3 "$XUIDB" "SELECT 1 FROM hosts LIMIT 1;" 2>/dev/null)" ]]; then
		sel=""
		cols=$(sqlite3 "$XUIDB" "SELECT name FROM pragma_table_info('hosts') WHERE name <> 'id';")
		for col in $cols; do
			case "$col" in
				address) sel+="'$ip'," ;;
				remark) sel+="coalesce(remark, '') || '-relay'," ;;
				sni|host_header) sel+="CASE WHEN coalesce($col, '') = '' AND security = 'tls' AND $is_dom THEN address ELSE $col END," ;;
				group_id) sel+="lower(hex(randomblob(8)))," ;;
				*) sel+="\"$col\"," ;;
			esac
		done
		n=$(sqlite3 "$XUIDB" "INSERT INTO hosts ($(echo $cols | sed 's/\([^ ]*\)/"\1"/g; s/ /,/g')) SELECT ${sel%,} FROM hosts h
			WHERE coalesce(h.remark, '') NOT LIKE '%-cfip' AND coalesce(h.remark, '') NOT LIKE '%-relay'
			AND NOT EXISTS (SELECT 1 FROM hosts x WHERE x.inbound_id = h.inbound_id AND x.address = '$ip');
			SELECT changes();")
		echo "added hosts: $n"
	else
		n=$(sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_insert(stream_settings, '\$.externalProxy[#]', json(
				CASE WHEN json_extract(stream_settings, '\$.externalProxy[0].forceTls') = 'tls'
				THEN json_set(json_extract(stream_settings, '\$.externalProxy[0]'), '\$.dest', '$ip', '\$.remark', 'relay',
					'\$.sni', json_extract(stream_settings, '\$.externalProxy[0].dest'))
				ELSE json_set(json_extract(stream_settings, '\$.externalProxy[0]'), '\$.dest', '$ip', '\$.remark', 'relay') END))
			WHERE json_type(stream_settings, '\$.externalProxy[0]') = 'object'
			AND instr(stream_settings, '\"$ip\"') = 0;
			SELECT changes();")
		echo "no hosts table rows, added to externalProxy of inbounds: $n"
	fi
	systemctl start x-ui
	hosts_show
	echo "backup: $bk"
	echo "undo: systemctl stop x-ui; cp $bk $XUIDB; systemctl start x-ui"
}

cmd_cfip() {
	local act="$1" ip="$2" d="${3:-$(panel_domain)}" bk sel col cols n
	[[ "$act" == add || "$act" == remove ]] || { echo "usage: xui-tools cfip add|remove <cloudflare-ip> [domain]"; exit 1; }
	[[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "bad IPv4: $ip"; exit 1; }
	[[ "$act" == remove || "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "cannot detect panel domain, pass it as 3rd argument"; exit 1; }
	bk="${XUIDB}.bak-cfip-$(date +%F_%H%M%S)"
	cp -a "$XUIDB" "$bk"
	systemctl stop x-ui
	if [[ "$act" == remove ]]; then
		hosts_remove "$ip"
	elif [[ -n "$(sqlite3 "$XUIDB" "SELECT 1 FROM hosts WHERE security = 'tls' AND address = '$d' LIMIT 1;" 2>/dev/null)" ]]; then
		sel=""
		cols=$(sqlite3 "$XUIDB" "SELECT name FROM pragma_table_info('hosts') WHERE name <> 'id';")
		for col in $cols; do
			case "$col" in
				address) sel+="'$ip'," ;;
				remark) sel+="remark || '-cfip'," ;;
				sni|host_header) sel+="'$d'," ;;
				group_id) sel+="lower(hex(randomblob(8)))," ;;
				*) sel+="\"$col\"," ;;
			esac
		done
		n=$(sqlite3 "$XUIDB" "INSERT INTO hosts ($(echo $cols | sed 's/\([^ ]*\)/"\1"/g; s/ /,/g')) SELECT ${sel%,} FROM hosts h
			WHERE h.security = 'tls' AND h.address = '$d'
			AND NOT EXISTS (SELECT 1 FROM hosts x WHERE x.inbound_id = h.inbound_id AND x.address = '$ip');
			SELECT changes();")
		echo "added hosts: $n"
	else
		n=$(sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_insert(stream_settings, '\$.externalProxy[#]',
				json_object('forceTls', 'tls', 'dest', '$ip', 'port', 443, 'remark', 'cfip', 'sni', '$d'))
			WHERE json_extract(stream_settings, '\$.externalProxy[0].dest') = '$d'
			AND json_extract(stream_settings, '\$.externalProxy[0].forceTls') = 'tls'
			AND instr(stream_settings, '\"$ip\"') = 0;
			SELECT changes();")
		echo "no tls hosts for $d in hosts table, added to externalProxy of inbounds: $n"
	fi
	systemctl start x-ui
	hosts_show
	echo "backup: $bk"
	echo "undo: systemctl stop x-ui; cp $bk $XUIDB; systemctl start x-ui"
}

tls_probe() {
	timeout 6 openssl s_client -connect "$1" -servername "$2" </dev/null 2>&1 \
		| grep -E '^CONNECTED|subject=|Verify return code|errno|error' | head -4 | sed 's/^/    /'
	[[ ${PIPESTATUS[0]} -eq 124 ]] && echo "    TIMEOUT"
}

cmd_diag() {
	local out rd pd since p
	out="/root/xui-diag-$(date +%F_%H%M%S).txt"
	pd=$(panel_domain)
	rd=$(awk '/server_name/{print $2; exit}' $(grep -l 'listen 9443' /etc/nginx/sites-enabled/* 2>/dev/null | head -1) 2>/dev/null | tr -d ';')
	since=$(date -d '-5 min' '+%Y/%m/%d %H:%M')
	{
		echo "== time"; date
		echo "== listening"; ss -ltnup | grep -E ':(443|7443|8443|9443) ' | awk '{print $1, $5, $7}'
		echo "== tcp states per port"
		for p in 443 7443 8443 9443; do
			echo "  $p: $(ss -Htan "( sport = :$p or dport = :$p )" | awk '{print $1}' | sort | uniq -c | xargs)"
		done
		echo "== nginx workers"
		for p in $(pgrep -f 'nginx: worker'); do
			echo "  pid $p cpu $(ps -o %cpu= -p "$p" | xargs)% fds $(ls /proc/"$p"/fd 2>/dev/null | wc -l) state $(awk '{print $3}' /proc/"$p"/stat)"
		done
		echo "== xray"; ps -o pid=,lstart=,%cpu=,rss= -p "$(pgrep -f xray-linux | head -1)"
		echo "== tls 9443 direct, nginx REALITY target ($rd)"; tls_probe 127.0.0.1:9443 "$rd"
		echo "== tls 443 with REALITY sni, nginx stream -> xray -> 9443"; tls_probe 127.0.0.1:443 "$rd"
		echo "== tls 443 with panel sni, nginx stream -> 7443 ($pd)"; tls_probe 127.0.0.1:443 "$pd"
		echo "== nginx errors since $since"
		awk -v s="$since" 'substr($0, 1, 16) >= s' /var/log/nginx/error.log \
			| sed -E 's/^.{20}//; s/\*[0-9]+ //; s/client: [^,]+,//' | cut -c1-110 | sort | uniq -c | sort -rn | head -15
	} 2>&1 | tee "$out"
	echo
	echo "saved: $out"
}

cmd_health() {
	for s in x-ui nginx AdGuardHome mtr-backend; do
		systemctl cat "${s}.service" &>/dev/null || continue
		printf "%-12s %s\n" "$s" "$(systemctl is-active "$s")"
	done
	echo
	nginx -t 2>&1 | tail -1
	[[ -n "$XRAY" ]] && "$XRAY" version | head -1
	echo
	for d in /etc/letsencrypt/live/*/; do
		[[ -f "${d}fullchain.pem" ]] || continue
		end=$(openssl x509 -enddate -noout -in "${d}fullchain.pem" | cut -d= -f2)
		left=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
		printf "cert %-40s %4d days left\n" "$(basename "$d")" "$left"
	done
	echo
	df -h / | tail -1 | awk '{print "disk  used " $3 " of " $2 " (" $5 ")"}'
	free -h | awk '/^Mem:/{print "mem   used " $3 " of " $2}'
	uptime -p
}

cmd_dns() {
	local port
	port=$(awk '/^dns:/{f=1} f&&/^  port:/{print $2; exit}' "$AGH_YAML" 2>/dev/null)
	[[ -n "$port" ]] || { echo "AdGuard Home DNS port not found in $AGH_YAML"; exit 1; }
	command -v dig &>/dev/null || { echo "install dig: apt install dnsutils"; exit 1; }
	for d in "${@:-wikipedia.org}"; do
		printf "%-25s %s  %s\n" "$d" "$(dig @127.0.0.1 -p "$port" "$d" +short | head -1)" "$(dig @127.0.0.1 -p "$port" "$d" | grep -o 'Query time: [0-9]* msec')"
	done
}

case "$1" in
	online) shift; cmd_online "$@" ;;
	clients) cmd_clients ;;
	history) cmd_history ;;
	snapshot) cmd_snapshot ;;
	conns) cmd_conns ;;
	top) cmd_top ;;
	traffic) cmd_traffic ;;
	watch) cmd_watch ;;
	backup) cmd_backup ;;
	ban) shift; cmd_ban "$@" ;;
	unban) shift; cmd_unban "$@" ;;
	autoban) shift; cmd_autoban "$@" ;;
	cert) shift; cmd_cert "$@" ;;
	site) shift; cmd_site "$@" ;;
	subpage) shift; cmd_subpage "$@" ;;
	diag) cmd_diag ;;
	why) shift; cmd_why "$@" ;;
	cfip) shift; cmd_cfip "$@" ;;
	relay) shift; cmd_relay "$@" ;;
	alias) shift; cmd_alias "$@" ;;
	health) cmd_health ;;
	dns) shift; cmd_dns "$@" ;;
	*)
		echo "usage: xui-tools <command>"
		echo "  online [proto] who is connected now, inbound, IP and last activity, e.g. 'online trojan'"
		echo "  clients        all clients: online now or not, last online, traffic, known IPs (from panel DB)"
		echo "  history        every client+IP ever seen: first and last time (needs snapshot in cron)"
		echo "  snapshot       save who is online now into $SEEN"
		echo "                 cron: (sudo crontab -l; echo '* * * * * /usr/local/bin/xui-tools snapshot') | sudo crontab -"
		echo "  conns          open connections on :443 per IP"
		echo "  top            live download/upload speed per client now (2s sample)"
		echo "  traffic        all-time up/down per client plus a total (from panel DB)"
		echo "  watch          live dashboard: online + top traffic, refreshes every 3s (Ctrl+C to quit)"
		echo "  backup         tar of db, nginx, certs, AdGuard, history to /root/xui-backups (keeps last 7)"
		echo "  ban <ip>       block an IP with ufw"
		echo "  unban <ip>     remove that ufw block"
		echo "  autoban [on|off|test]  fail2ban: ban IPs with many 404/444 (scanners), VPN paths and Cloudflare ignored"
		echo "  cert [force]   renew certificates now (stops nginx briefly); 'force' reissues even if not due"
		echo "  site [1-50]    replace fake cover site, random if no number, previous kept in /var/www/html.prev"
		echo "  subpage [0|1]  reinstall web sub page (0 modern, 1 classical) with paths from panel and nginx"
		echo "  alias add|remove <domain>  extra name for the panel site and subscription, e.g. a subdomain pointing to a relay"
		echo "  relay add|remove <ip>  copy every host (REALITY, ws, gRPC, xhttp, hysteria) with a relay server IP as address (-relay links)"
		echo "  cfip add|remove <ip> [domain]  copy tls hosts of the panel domain with a Cloudflare IP as address (-cfip links)"
		echo "  why <domain> [email]  why a site does not open: server reach, AdGuard, xray log lines"
		echo "  diag           snapshot when VPN breaks: ports, nginx workers, TLS checks of 9443/443, recent nginx errors, saved to /root"
		echo "  health         services, nginx config, certificates, disk, memory"
		echo "  dns [domains]  AdGuard answer and lookup time, 0.0.0.0 means blocked"
		;;
esac

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

valid_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" == *:* ]]; }

cmd_ban() {
	valid_ip "$1" || { echo "usage: xui-tools ban <ip>"; exit 1; }
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
	cert) shift; cmd_cert "$@" ;;
	site) shift; cmd_site "$@" ;;
	subpage) shift; cmd_subpage "$@" ;;
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
		echo "  cert [force]   renew certificates now (stops nginx briefly); 'force' reissues even if not due"
		echo "  site [1-50]    replace fake cover site, random if no number, previous kept in /var/www/html.prev"
		echo "  subpage [0|1]  reinstall web sub page (0 modern, 1 classical) with paths from panel and nginx"
		echo "  health         services, nginx config, certificates, disk, memory"
		echo "  dns [domains]  AdGuard answer and lookup time, 0.0.0.0 means blocked"
		;;
esac

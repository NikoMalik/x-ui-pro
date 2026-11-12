#!/bin/bash
[[ $EUID -ne 0 ]] && echo "Run as root: sudo bash $0 -target <main-ip-or-domain>" && exit 1
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}

NGX="${NGX:-/etc/nginx}"
target=""
udp="y"
uninstall="n"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -target) target="$2"; shift 2;;
    -udp) udp="$2"; shift 2;;
    -uninstall) uninstall="$2"; shift 2;;
    *) shift 1;;
  esac
done

if [[ "$uninstall" == *y* ]]; then
	rm -f "$NGX/stream-enabled/relay.conf"
	nginx -t && systemctl reload nginx
	msg_ok "Relay removed, nginx kept"
	exit 0
fi

while [[ -z "$target" ]]; do
	echo -en "Main server IP or REALITY domain (grey cloud, not Cloudflare): " && read target
done
target=$(echo "$target" | tr -d '[:space:]')
[[ "$target" =~ ^[A-Za-z0-9.-]+$ ]] || { msg_err "Bad target: $target"; exit 1; }

if [[ "$target" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
	main_ip="$target"
else
	main_ip=$(getent ahostsv4 "$target" | awk 'NR==1{print $1}')
	[[ -n "$main_ip" ]] || { msg_err "$target does not resolve"; exit 1; }
fi
if [[ "$main_ip" =~ ^(104\.(1[6-9]|2[0-7])\.|131\.0\.7[2-5]\.|172\.(6[4-9]|7[01])\.|188\.114\.(9[6-9]|10[0-9]|11[01])\.|162\.15[89]\.|141\.101\.|108\.162\.|190\.93\.|197\.234\.|198\.41\.|173\.245\.|103\.(21|22|31)\.) ]]; then
	msg_err "$target -> $main_ip is Cloudflare, REALITY can not go through it, use the main server IP or the REALITY domain"
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nginx libnginx-mod-stream netcat-openbsd ufw curl

if ! nc -z -w 5 "$main_ip" 443; then
	msg_err "Relay can not reach $main_ip:443, check the main server firewall or try another relay provider"
	exit 1
fi

rm -f "$NGX/sites-enabled/default"
mkdir -p "$NGX/stream-enabled"
grep -qF "stream-enabled/*.conf" "$NGX/nginx.conf" || echo "stream { include $NGX/stream-enabled/*.conf; }" >> "$NGX/nginx.conf"
sed -i '/^\s*worker_rlimit_nofile/d' "$NGX/nginx.conf"
sed -i "/worker_connections/c\    worker_connections 16384;" "$NGX/nginx.conf"
echo "worker_rlimit_nofile 200000;" >> "$NGX/nginx.conf"

{
	cat <<EOF
server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass $main_ip:443;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
}
server {
    listen 80;
    listen [::]:80;
    proxy_pass $main_ip:80;
    proxy_connect_timeout 5s;
    proxy_timeout 60s;
}
EOF
	[[ "$udp" == *y* ]] && cat <<EOF
server {
    listen 443 udp;
    listen [::]:443 udp;
    proxy_pass $main_ip:443;
    proxy_timeout 1h;
}
EOF
} > "$NGX/stream-enabled/relay.conf"

[[ -f /proc/net/if_inet6 ]] || sed -i '/listen \[::\]/d' "$NGX/stream-enabled/relay.conf"

cat > /etc/sysctl.d/90-relay.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF
modprobe nf_conntrack 2>/dev/null && echo nf_conntrack > /etc/modules-load.d/conntrack.conf
cat > /etc/sysctl.d/91-relay-conntrack.conf <<'EOF'
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
sysctl --system >/dev/null 2>&1

ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
[[ "$udp" == *y* ]] && ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

if ! nginx -t; then
	msg_err "nginx config failed, see above"
	exit 1
fi
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

relay_ip=$(curl -s4 --max-time 10 ipv4.icanhazip.com | tr -d '[:space:]')
msg_ok "Relay ready: ${relay_ip:-this server}:443 -> $main_ip:443 (tcp$([[ "$udp" == *y* ]] && echo ' + udp'))"
msg_inf "On the main server run:  xui-tools relay add ${relay_ip:-RELAY_IP}"
msg_inf "Clients update the subscription and use the -relay profiles"
msg_inf "Remove:  sudo bash $0 -uninstall y"

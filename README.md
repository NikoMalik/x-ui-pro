## x-ui-pro (x-ui + nginx) modification of https://github.com/GFW4Fun/x-ui-pro for REALITY
- Auto Installation (lightweight)
- Auto SSL renewal / Daily reload Nginx X-ui
- Handle **REALITY** and **WebSocket** via **nginx**.
- Multi-user and config via port **443**
- Auto enabled subscriptions via port **443**
- Auto configured VLESS+Reality, VLESS+WebSocket, VLESS+XHTTP, Trojan+gRPC and Hysteria2 (UDP 443, salamander obfs)
- Nginx tuned for many clients and long gRPC sessions (connection limits, HTTP/2 streams, TLS session reuse, stream timeouts)
- Real client IP in nginx logs, no internal `:7443` in redirects
- **Custom Web Sub Page**
- Feature that allows the use of **custom client configurations for SING-BOX & CLASH META**
- **Local instance sub2sing-box**
- Auto configured Firewall
- More security and low detection with nginx
- Compatible with Cloudflare (only for WebSocket/GRPC)
- Random 150+ fake template!
- Linux Debian12/Ubuntu24!
  >
   **You need TWO domains or subdomains**
  1. For panel and WebSocket/GRPC/HttpUgrade/SplitHttp
  2. For REALITY destination
  >
  Get Free subdomains - https://scarce-hole-1e2.notion.site/14d1666462e48069818cf42553bfae1f?pvs=74
  
  
➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖

### Install X-UI-PRO

```
bash <(wget -qO- https://github.com/NikoMalik/x-ui-pro/raw/master/x-ui-pro.sh) -install yes -panel 1 -ONLY_CF_IP_ALLOW no
```
> 
> Do not change SubDomain for renew SSL❗ To move to a new subdomain use the patch below

**Install without Clash** (only for v2ray/xray/sing-box clients like Happ, OneXray, v2rayN, Hiddify)
```
bash <(wget -qO- https://github.com/NikoMalik/x-ui-pro/raw/master/x-ui-pro.sh) -install yes -clash no
```

| option | values |
|---|---|
| `-install` | `yes` install packages, needed on a clean server |
| `-subdomain` | panel domain, asked if not set |
| `-reality_domain` | REALITY domain, asked if not set |
| `-websub` | `0` modern sub page, `1` classic |
| `-clash` | `0` ru-bundle, `1` skrepysh, `2` full proxy except RU, `3` re-filter ECH, `no` skip Clash template |
| `-hysteria` | `y` default, add Hysteria2 inbound on UDP 443, `n` skip it |
| `-auto_domain` | `y` use `IP.cdn-one.org` domains |
| `-uninstall` | `yes` remove everything |


**Uninstall X-UI-PRO**:x:
```
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/x-ui-pro.sh) -uninstall yes"
```

**backup panel and nginx configs**:x:
```
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/backup.sh)"
```

### Hysteria2

Added by default as a 5th inbound, client `firstH` in the same subscription as the others (subId `first`)
- UDP 443, nginx only listens TCP 443 so there is no conflict, ufw opens `443/udp`
- TLS with the REALITY domain Let's Encrypt cert, SNI is the REALITY domain, ALPN `h3`
- salamander obfs with a random password, link address is the server IP
- needs a client with Hysteria2 support, xray based (OneXray, v2rayN) or sing-box based (sing-box, Hiddify, Karing)
- some mobile networks throttle UDP, then use REALITY or Trojan+gRPC

Skip it with `-hysteria n`

**Add or fix Hysteria2 on an existing install**
```
wget -qO patch_hysteria.sh https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/patch_hysteria.sh
sudo bash patch_hysteria.sh
```
- no Hysteria inbound yet: creates one on UDP 443 with client `firstH` in your existing subscription
- Hysteria inbound already there: keeps its port and clients (adds `firstH` only if it has none), sets REALITY domain cert and SNI, ALPN `h3`, server IP as link address, enables sniffing, adds salamander only if missing so current obfs passwords keep working
- options: `-email name` `-port 443` `-subid id` `-reality_domain domain`
- DB backup goes to `/root/patch_hysteria_backup_<date>.db`, clients re-import the subscription after it

### Move an existing install to a new panel or REALITY subdomain

Use it when a domain gets blocked or throttled. Issues certs for the new subdomains, replaces them in nginx, panel settings, inbounds, hosts and the web sub page, sets REALITY address to the server IP and fingerprint to chrome, adds stream `proxy_timeout` and fixes the certbot cron. Clients and keys stay, users only update the subscription. `-relay` and `-cfip` hosts keep their addresses. A backup is saved to `/root/patch_old_backup_<date>/`
```
wget -qO patch_old.sh https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/patch_old.sh
sudo bash patch_old.sh -subdomain new.example.com
sudo bash patch_old.sh -reality_domain r.example.com
sudo bash patch_old.sh -subdomain new.example.com -reality_domain r.example.com
```
- the new REALITY subdomain must point to the server IP with a grey cloud (DNS only), a Cloudflare address is refused
- the new panel subdomain can be grey or already behind Cloudflare, then **Always Use HTTPS** must be off so the cert check over port 80 passes
- `-old_domain` and `-old_reality` override the auto detected current domains

### Relay server in the users country

When the ISP blocks the main server IP, put a small VPS in the users country (local provider, not a big international one) that forwards TCP and UDP 443 to the main server. Nothing is decrypted on it, keys, certs and domains stay the same

On the relay (Debian/Ubuntu):
```
wget -qO relay_setup.sh https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/relay_setup.sh
sudo bash relay_setup.sh -target MAIN_SERVER_IP
```
`-target` takes the main server IP or the REALITY domain (grey cloud), a Cloudflare address is refused. `-udp n` skips UDP (no Hysteria2), `-uninstall y` removes the relay config

On the main server:
```
xui-tools relay add RELAY_IP
```
Users update the subscription and pick the `-relay` profiles. If the subscription domain itself is blocked for them, send one `-relay` link by hand first, then update the subscription through the VPN

Site and subscription through the relay: create a subdomain with an A record to the relay IP (grey cloud), then on the main server
```
xui-tools alias add m.example.com
```
It issues a cert for the name (the relay forwards port 80 to the main server for that), adds the name to the stream map and as a copy of the panel vhost. Users of that region open `https://m.example.com/` and use `https://m.example.com/<subPath>/<subId>` as subscription. `xui-tools alias remove m.example.com` undoes it

### Server tools

```
sudo wget -qO /usr/local/bin/xui-tools https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/xui-tools.sh
sudo chmod +x /usr/local/bin/xui-tools
xui-tools
```

| command | what it shows or does |
|---|---|
| `online [proto]` | who is connected now, inbound, IP, last activity, e.g. `online trojan` |
| `clients` | all clients, online or not, last online, traffic, known IPs |
| `history` | every client and IP ever seen, needs `snapshot` in cron, see `xui-tools` output |
| `top` / `watch` | live speed per client / live dashboard |
| `traffic` | all-time traffic per client |
| `conns` | open connections on :443 per IP |
| `health` | services, nginx config, cert days left, disk, memory |
| `cert [force]` | renew certs now, stops nginx for a few seconds |
| `dns [domains]` | AdGuard Home answer and lookup time |
| `site [1-50]` | replace the fake cover site |
| `subpage [0\|1]` | reinstall the web sub page with current paths |
| `backup` | tar of db, nginx, certs to `/root/xui-backups`, keeps last 7 |
| `ban <ip>` / `unban <ip>` | block or unblock an IP with ufw, local and private IPs refused |
| `autoban [on\|off\|test]` | fail2ban bans IPs with 30+ 404/444 in 10 min for 1 day, VPN, subscription and panel paths plus Cloudflare ranges are ignored |
| `why <domain> [email]` | why a site does not open through the VPN |
| `relay add\|remove <ip>` | add `-relay` copies of every host with a relay server IP as address, for a forwarding server in the users country |
| `cfip add\|remove <ip>` | add `-cfip` copies of the panel domain TLS hosts with a Cloudflare IP as address |
| `diag` | snapshot when the VPN breaks, ports, nginx workers, TLS checks |

Clients on WebSocket, XHTTP and Trojan go through nginx, so xray sees them as `127.0.0.1` and `online`/`history` do not list them yet. Use `top` to see their traffic

➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖➖
### Screenshots :wrench:🐧⚙️
>
**How to open custom web sub page?**
>
![](https://github.com/legiz-ru/x-ui-pro/blob/master/media/CustomWebSubHow2Open.png?raw=true)
>
**Main Page custom web sub**
>
![](https://github.com/legiz-ru/x-ui-pro/blob/master/media/CustomWebSub.png?raw=true)
>
**sub2sing-box section on custom web sub page**
>
![](https://github.com/legiz-ru/x-ui-pro/blob/master/media/CustomWebSubSingBox.png?raw=true)
>
**local instance sub2sing-box fork by legiz**
>
![](https://github.com/legiz-ru/x-ui-pro/blob/master/media/sub2sing.png?raw=true)

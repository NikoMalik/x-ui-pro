## x-ui-pro (x-ui + nginx) modification of https://github.com/GFW4Fun/x-ui-pro for REALITY
- Auto Installation (lightweight)
- Auto SSL renewal / Daily reload Nginx X-ui
- Handle **REALITY** and **WebSocket** via **nginx**.
- Multi-user and config via port **443**
- Auto enabled subscriptions via port **443**
- Auto configured VLESS+Reality, VLESS+WebSocket, VLESS+XHTTP and Trojan+gRPC
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

### Move an existing install to a new panel subdomain

Use it when the panel domain gets blocked or throttled. Issues a cert for the new subdomain, replaces the domain in nginx, panel settings, inbounds and the web sub page, sets REALITY address to the server IP and fingerprint to chrome, adds stream `proxy_timeout` and fixes the certbot cron. Clients and keys stay, users only re-import the subscription with the new domain. A backup is saved to `/root/patch_old_backup_<date>/`

The new subdomain must already point to the server IP
```
wget -qO patch_old.sh https://raw.githubusercontent.com/NikoMalik/x-ui-pro/master/patch_old.sh
sudo bash patch_old.sh -subdomain new.example.com
```

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
| `ban <ip>` / `unban <ip>` | block or unblock an IP with ufw |

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

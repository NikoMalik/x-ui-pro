#!/usr/bin/env python3
import sys
from datetime import datetime, timedelta

GAP = timedelta(minutes=5)


def parse(line):
    parts = line.split()
    if len(parts) < 6 or parts[2] != "from" or "accepted" not in parts:
        return None
    if "[api" in line:
        return None
    try:
        ts = datetime.strptime(parts[0] + " " + parts[1][:15], "%Y/%m/%d %H:%M:%S.%f")
    except ValueError:
        return None
    src = parts[3]
    for p in ("tcp:", "udp:"):
        if src.startswith(p):
            src = src[len(p):]
    ip = src.rsplit(":", 1)[0].strip("[]")
    inbound = next((t[1:] for t in parts if t.startswith("[")), "?")
    email = parts[parts.index("email:") + 1] if "email:" in parts and parts.index("email:") + 1 < len(parts) else "-"
    return ts, ip, email, inbound


def sessions(lines):
    open_s = {}
    done = []
    recs = sorted(filter(None, map(parse, lines)), key=lambda r: r[0])
    for ts, ip, email, inbound in recs:
        key = (email, ip)
        s = open_s.get(key)
        if s and ts - s["end"] <= GAP:
            s["end"] = ts
            s["count"] += 1
            s["inbounds"].add(inbound)
        else:
            if s:
                done.append(s)
            open_s[key] = {"email": email, "ip": ip, "start": ts, "end": ts, "count": 1, "inbounds": {inbound}}
    return done + list(open_s.values())


def fmt(d):
    m = int(d.total_seconds() // 60)
    return f"{m // 60}h{m % 60:02d}m"


def main():
    paths = sys.argv[1:] or ["/var/log/x-ui/access.log"]
    lines = []
    for path in paths:
        with open(path, errors="replace") as f:
            lines.extend(f)
    all_s = sessions(lines)
    now = datetime.now()
    all_s.sort(key=lambda s: s["end"])
    print(f"{'status':8} {'email':12} {'ip':40} {'start':19} {'last seen':19} {'dur':>7} {'conns':>6} inbound")
    for s in all_s:
        status = "ONLINE" if now - s["end"] <= GAP else "off"
        print(f"{status:8} {s['email']:12} {s['ip']:40} {s['start']:%Y-%m-%d %H:%M:%S} {s['end']:%Y-%m-%d %H:%M:%S} "
              f"{fmt(s['end'] - s['start']):>7} {s['count']:>6} {','.join(sorted(s['inbounds']))}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        log = [
            "2026/10/31 18:00:00.000001 from 1.2.3.4:100 accepted tcp:a.com:443 [in-8443-tcp >> direct] email: first",
            "2026/10/31 18:03:00.000001 from 1.2.3.4:101 accepted tcp:b.com:443 [in-8443-tcp >> direct] email: first",
            "2026/10/31 18:20:00.000001 from 1.2.3.4:102 accepted tcp:c.com:443 [in-8443-tcp >> direct] email: first",
            "2026/10/31 18:01:00.000001 from tcp:[2001:db8::1]:5 accepted udp:1.1.1.1:53 [in-8443-tcp -> adguard-dns] email: second",
            "2026/10/31 18:02:00.000001 from 127.0.0.1:5 accepted tcp:127.0.0.1:62789 [api -> api]",
            "garbage",
        ]
        r = sessions(log)
        assert len(r) == 3, r
        first = sorted((s for s in r if s["email"] == "first"), key=lambda s: s["start"])
        assert first[0]["count"] == 2 and first[1]["count"] == 1
        assert any(s["ip"] == "2001:db8::1" and s["email"] == "second" for s in r)
        print("ok")
    else:
        main()

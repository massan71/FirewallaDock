#!/usr/bin/env python3
"""Probe the Firewalla MSP API and report the real response shapes.

Prompts for the base URL and token (the token is never echoed or stored).
Writes a structure report and one sample item per endpoint to build/probe/
(ignored by git) so the app's decoders can be checked against real data.
"""
import getpass, json, os, sys, urllib.error, urllib.parse, urllib.request

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "probe")

def shape(v, depth=0):
    if isinstance(v, dict):
        if depth > 2: return "object"
        return {k: shape(x, depth + 1) for k, x in sorted(v.items())}
    if isinstance(v, list):
        return [shape(v[0], depth + 1)] if v else []
    if v is None: return "null"
    return type(v).__name__

def merge_keys(items):
    keys = {}
    for it in items:
        if isinstance(it, dict):
            for k, x in it.items():
                keys.setdefault(k, set()).add("null" if x is None else type(x).__name__)
    return {k: sorted(t) for k, t in sorted(keys.items())}

def main():
    base = os.environ.get("FIREWALLA_URL", "").strip()
    while True:
        if not base:
            base = input("API base URL (e.g. https://yourdomain.firewalla.net or https://firewalla.net/api): ").strip()
        if base and not base.startswith("http"):
            base = "https://" + base
        base = base.rstrip("/")
        parsed = urllib.parse.urlparse(base)
        if parsed.scheme != "https":
            print("  Only https:// URLs are allowed (the token must never be sent unencrypted). Please try again.")
            base = ""
            continue
        if parsed.hostname:
            break
        print("  That is not a valid URL, please try again.")
        base = ""
    token = os.environ.get("FIREWALLA_TOKEN", "").strip()
    while not token:
        token = getpass.getpass("API token (hidden, paste and press Enter): ").strip()
        if not token:
            print("  The token is empty, please try again.")
    print(f"Using {base} with a {len(token)}-character token\n")

    if "--count-alarms" in sys.argv:
        count_alarms(base, token)
        return

    probes = [
        ("boxes", "/v2/boxes", {}),
        ("devices", "/v2/devices", {}),
        ("alarms_active", "/v2/alarms", {"query": "status:active", "limit": "5"}),
        ("alarms_all", "/v2/alarms", {"limit": "5"}),
        ("flows", "/v2/flows", {"limit": "5"}),
        ("flows_blocked", "/v2/flows", {"query": "block:true", "limit": "5"}),
        ("rules", "/v2/rules", {}),
        ("trend_alarms", "/v2/trends/alarms", {}),
        ("trend_flows", "/v2/trends/flows", {}),
    ]
    os.makedirs(OUT, exist_ok=True)
    report = {}
    for name, path, q in probes:
        url = base + path + ("?" + urllib.parse.urlencode(q) if q else "")
        req = urllib.request.Request(url, headers={"Authorization": "Token " + token, "Accept": "application/json"})
        entry = {"path": path, "query": q}
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                entry["status"] = r.status
                data = json.load(r)
        except urllib.error.HTTPError as e:
            entry["status"] = e.code
            entry["error"] = e.read().decode("utf-8", "replace")[:300]
            report[name] = entry
            print(f"{name:15} HTTP {e.code}")
            continue
        except Exception as e:
            entry["error"] = repr(e)
            report[name] = entry
            print(f"{name:15} ERROR {e!r}")
            continue

        if isinstance(data, list):
            entry["kind"] = "array"
            items = data
        elif isinstance(data, dict) and "results" in data:
            entry["kind"] = "page"
            items = data.get("results") or []
            entry["wrapper"] = {k: (v if k != "results" else f"<{len(items)} items>") for k, v in data.items()}
        else:
            entry["kind"] = "other"
            entry["shape"] = shape(data)
            items = []
        entry["item_count"] = len(items)
        entry["fields"] = merge_keys(items)
        if items:
            entry["sample_shape"] = shape(items[0])
        report[name] = entry
        with open(os.path.join(OUT, name + ".json"), "w") as f:
            json.dump(data, f, indent=2)
        print(f"{name:15} HTTP {entry['status']}  {entry['kind']:5}  {len(items)} items")

    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(report, f, indent=2)
    print("\nReport written to build/probe/report.json")

SECURITY_TYPES = {1, 2, 10, 13, 14, 16}  # must match AlarmType.isSecurity in the app

def fetch(base, token, path, q):
    url = base + path + "?" + urllib.parse.urlencode(q)
    req = urllib.request.Request(url, headers={"Authorization": "Token " + token, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

def count_alarms(base, token):
    """Count every active alarm (all pages) and compare with the box alarmCount. Writes counts only."""
    boxes = fetch(base, token, "/v2/boxes", {})
    by_type, statuses, total, pages, cursor = {}, {}, 0, 0, None
    while True:
        q = {"query": "status:active", "limit": "500"}
        if cursor: q["cursor"] = cursor
        page = fetch(base, token, "/v2/alarms", q)
        pages += 1
        for a in page.get("results") or []:
            total += 1
            by_type[a.get("type")] = by_type.get(a.get("type"), 0) + 1
            statuses[a.get("status")] = statuses.get(a.get("status"), 0) + 1
        cursor = page.get("next_cursor")
        if not cursor or not page.get("results") or pages > 50:
            break
    result = {
        "box_alarmCount": {b.get("name"): b.get("alarmCount") for b in boxes},
        "active_alarms_total": total,
        "security_alarms": sum(n for t, n in by_type.items() if t in SECURITY_TYPES),
        "by_type": {str(k): v for k, v in sorted(by_type.items(), key=lambda kv: str(kv[0]))},
        "statuses": {str(k): v for k, v in statuses.items()},
        "pages": pages,
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "alarm_counts.json"), "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result, indent=2))
    print("\nWritten to build/probe/alarm_counts.json")

if __name__ == "__main__":
    main()

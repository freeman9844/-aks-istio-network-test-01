"""kubectl·az JSON 집계(03-verify.ps1 의 Get-PodZoneCounts, Get-ScaleEventNote 등 이식)."""
import sys

from aksnetval import _cli
from aksnetval.parse import zone_key

ZONES = ("1", "2", "3")


def _alive(items: list) -> list:
    return [p for p in items if "deletionTimestamp" not in p.get("metadata", {})]


def _zone_of(nodes: dict) -> dict[str, str]:
    return {n["metadata"]["name"]: zone_key(n["metadata"].get("labels", {}).get("topology.kubernetes.io/zone")) for n in nodes.get("items", [])}


def node_zone_counts(nodes: dict) -> dict[str, int]:
    counts: dict[str, int] = {}
    for z in _zone_of(nodes).values():
        if z:
            counts[z] = counts.get(z, 0) + 1
    return counts


def node_targets(nodes: dict, pods: dict) -> dict:
    """대상 Pod 가 있는 노드(host 엔터티)와 다른 노드(remote-node 엔터티)의 InternalIP."""
    ips = {n["metadata"]["name"]: next((a["address"] for a in n.get("status", {}).get("addresses", []) if a.get("type") == "InternalIP"), "")
           for n in nodes.get("items", [])}
    own = next((p.get("spec", {}).get("nodeName", "") for p in _alive(pods.get("items", [])) if p.get("spec", {}).get("nodeName")), "")
    other = next((n for n in sorted(ips) if n != own and ips[n]), "")
    if not ips.get(own) or not other:
        raise ValueError(f"노드 IP 를 찾지 못했습니다(own={own or '없음'}, 노드 {len(ips)}대)")
    return {"own_node": own, "own_ip": ips[own], "other_node": other, "other_ip": ips[other]}


def pod_zone_counts(nodes: dict, pods: dict) -> dict:
    zone_of = _zone_of(nodes)
    counts: dict[str, int] = {}
    running = pending = 0
    names = []
    for p in _alive(pods.get("items", [])):
        names.append(p["metadata"]["name"])
        phase = p.get("status", {}).get("phase")
        if phase == "Pending":
            pending += 1
            continue
        if phase != "Running":
            continue
        running += 1
        z = zone_of.get(p.get("spec", {}).get("nodeName", ""), "")
        if z:
            counts[z] = counts.get(z, 0) + 1
    return {"counts": counts, "running": running, "pending": pending, "names": names}


def probe_items(pods: dict, ns: str) -> list[dict]:
    out = []
    for p in _alive(pods.get("items", [])):
        app = next((c for c in p["spec"]["containers"] if c["name"] == "app"), {})
        hg = app.get("readinessProbe", {}).get("httpGet")
        port = str(hg["port"]) if hg else None
        path = str(hg["path"]) if hg else None
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in p.get("status", {}).get("conditions", []))
        out.append({"name": f"{ns}/{p['metadata']['name']}", "ready": ready, "port": port, "path": path})
    return out


def _unique(seq: list[str]) -> list[str]:
    return list(dict.fromkeys(seq))


def scale_event_note(events: dict, pod_names: list[str], pending: int) -> str:
    names = set(pod_names)
    ev = [e for e in events.get("items", []) if e["involvedObject"].get("kind") == "Pod" and e["involvedObject"].get("name") in names]
    ups = _unique([e["message"] for e in ev if e.get("reason") == "TriggeredScaleUp"])
    scale = "TriggeredScaleUp: " + " / ".join(ups) if ups else "TriggeredScaleUp 이벤트 없음"
    parts = []
    if pending > 0:
        causes = _unique([f"{e['reason']}: {e['message']}" for e in ev if e.get("reason") in ("FailedScheduling", "NotTriggerScaleUp", "FailedScaleUp")])[-3:]
        parts.append("Pending 사유: " + (" / ".join(causes) if causes else "이벤트 없음"))
    parts.append(scale)
    return "; ".join(parts)


def fmt_counts(counts: dict) -> str:
    return ", ".join(f"영역{z}={counts.get(z, 0)}" for z in ZONES)


def fmt_short(counts: dict) -> str:
    return "/".join(str(counts.get(z, 0)) for z in ZONES)


def nodes_at_min(counts: dict, user_min: int) -> bool:
    return all(counts.get(z) == user_min for z in ZONES)


def aks_zone_setting(aks: dict, pools: list[str]) -> dict:
    balance = str(aks.get("autoScalerProfile", {}).get("balanceSimilarNodeGroups")).lower()
    profiles = {p["name"]: p for p in aks.get("agentPoolProfiles", [])}
    zones = []
    for p in pools:
        az = (profiles.get(p) or {}).get("availabilityZones")
        zones.append(f"{p}=" + ("+".join(az) if az else "없음"))
    expected = [f"{p}={i + 1}" for i, p in enumerate(pools)]
    return {"ok": balance == "true" and zones == expected, "setting": f"balanceSimilarNodeGroups={balance}; {', '.join(zones)}"}


def main(argv: list[str]) -> int:
    return _cli.run(globals(), argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

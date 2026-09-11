"""Generates homelab-overview.json - the Homelab Overview dashboard.

The one dashboard to open first. Everything else in this Grafana is a
drill-down: Kubernetes Views, Proxmox via Prometheus, Node Exporter Full,
Longhorn, ZFS. This page answers "is the estate healthy" in one screen and is
deliberately short - a panel earns its place only if a bad value on it would
change what happens next. Rows run top to bottom by urgency: yes/no status,
backups and certificates, Kubernetes, internet, hosts, power.

Not imported from grafana.com. Every published homelab overview assumes
equipment this estate does not have (UniFi, SNMP PDUs, Ceph), and the UPS half
could not be imported at all: the popular NUT dashboard (14371) queries a
different exporter's metric names.

To change it: edit this file, run `python3 homelab-overview.py`, commit both.
kustomize packs the JSON into the grafana-dashboard-homelab ConfigMap (see
../kustomization.yaml) and the Grafana sidecar provisions it, so an edit made
in the Grafana UI is overwritten on the next reconcile. Generated rather than
hand-written because the JSON is ~1500 lines of repetition, and because the
refId check at the bottom exists: a panel with two queries sharing refId "A"
is rejected by Grafana, and that bug shipped once.
"""
from pathlib import Path
import json

DS = {"type": "prometheus", "uid": "prometheus"}
pid = [0]
def nid():
    pid[0] += 1
    return pid[0]

def tgt(expr, legend=None, instant=False, ref="A"):
    t = {"datasource": DS, "editorMode": "code", "expr": expr, "range": not instant,
         "instant": instant, "refId": ref}
    if legend is not None:
        t["legendFormat"] = legend
    return t

def targets(*pairs):
    # one refId per query - Grafana rejects a panel whose queries share one
    return [tgt(e, l, ref=chr(ord("A") + i)) for i, (e, l) in enumerate(pairs)]

def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}

GREEN = {"color": "green", "value": None}

def stat(title, expr, x, y, w=3, h=4, unit="none", decimals=None, mappings=None,
         steps=None, desc="", text_size=None):
    d = {"color": {"mode": "thresholds"}, "unit": unit, "mappings": mappings or [],
         "thresholds": {"mode": "absolute", "steps": steps or [{"color": "text", "value": None}]}}
    if decimals is not None:
        d["decimals"] = decimals
    opts = {"colorMode": "value", "graphMode": "none", "justifyMode": "center",
            "orientation": "auto", "textMode": "value", "wideLayout": True,
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}
    if text_size:
        opts["text"] = {"valueSize": text_size}
    return {"id": nid(), "type": "stat", "title": title, "description": desc,
            "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": []}, "options": opts,
            "targets": [tgt(expr, instant=True)]}

def updown(title, expr, x, y, up_text, down_text, desc="", w=3):
    return stat(title, expr, x, y, w=w, desc=desc, text_size=26, mappings=[
        {"type": "value", "options": {
            "1": {"text": up_text, "color": "green", "index": 0},
            "0": {"text": down_text, "color": "red", "index": 1}}}])

def ts(title, tg, x, y, w=12, h=7, unit="none", desc="", minv=None, maxv=None,
       decimals=None, step=False, overrides=None):
    d = {"color": {"mode": "palette-classic"}, "unit": unit, "mappings": [],
         "thresholds": {"mode": "absolute", "steps": [GREEN]},
         "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 12,
                    "gradientMode": "opacity", "showPoints": "never", "spanNulls": True,
                    "lineInterpolation": "stepAfter" if step else "smooth",
                    "axisPlacement": "auto", "axisBorderShow": False,
                    "scaleDistribution": {"type": "linear"},
                    "stacking": {"group": "A", "mode": "none"},
                    "thresholdsStyle": {"mode": "off"},
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False}}}
    if minv is not None: d["min"] = minv
    if maxv is not None: d["max"] = maxv
    if decimals is not None: d["decimals"] = decimals
    return {"id": nid(), "type": "timeseries", "title": title, "description": desc,
            "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": overrides or []},
            "options": {"legend": {"calcs": ["lastNotNull", "min", "max"], "displayMode": "table",
                                   "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": tg}

def bargauge(title, expr, legend, x, y, w=12, h=9, unit="percentunit", steps=None,
             desc="", minv=0, maxv=None, decimals=1):
    d = {"color": {"mode": "thresholds"}, "unit": unit, "min": minv, "decimals": decimals,
         "mappings": [], "thresholds": {"mode": "absolute", "steps": steps}}
    if maxv is not None: d["max"] = maxv
    return {"id": nid(), "type": "bargauge", "title": title, "description": desc,
            "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": d, "overrides": []},
            "options": {"displayMode": "gradient", "orientation": "horizontal",
                        "showUnfilled": True, "valueMode": "color", "namePlacement": "left",
                        "sizing": "auto", "minVizWidth": 8, "minVizHeight": 14, "maxVizHeight": 24,
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "targets": [tgt(expr, legend, instant=True)]}

def age(title, expr, x, y, warn, crit, desc="", w=6):
    s = stat(title, expr, x, y, w=w, unit="s", decimals=1, desc=desc,
             steps=[GREEN, {"color": "yellow", "value": warn}, {"color": "red", "value": crit}])
    # absent means the producer has never reported, which is not "fine"
    s["fieldConfig"]["defaults"]["noValue"] = "no report"
    return s

# A failed speedtest sets every gauge to 0. Plotted raw, that reads as the
# line dropping to nothing, so results only count when speedtest_up says
# the run worked.
OK = " and on(instance) speedtest_up == 1"
DRAW = "network_ups_tools_ups_load / 100 * network_ups_tools_ups_realpower_nominal"
WAN_RTT = 'probe_duration_seconds{job="blackbox-wan"} and probe_success{job="blackbox-wan"} == 1'

P = []

# 1 ---------------------------------------------------------- right now
# Every tile here is a yes/no or a count that should be zero. If they are
# all green there is no reason to scroll.
P.append(row("Right now", 0))
P.append(stat("Alerts", 'count(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}) or vector(0)',
              0, 1, steps=[GREEN, {"color": "yellow", "value": 1}, {"color": "red", "value": 3}],
              desc="Firing in Alertmanager, excluding the Watchdog heartbeat."))
P.append(updown("Mains", 'network_ups_tools_ups_status{flag="OL"}', 3, 1, "On mains", "BATTERY",
                desc="ups.status OL flag from the UPS on pve-2."))
P.append(updown("Internet", 'max(probe_success{job="blackbox-wan"})', 6, 1, "Online", "OFFLINE",
                desc="TCP connect to 1.1.1.1 and 8.8.8.8. Offline only when both fail."))
P.append(updown("VPS", 'probe_success{job="blackbox-vps"}', 9, 1, "Reachable", "DOWN",
                desc="inside.merox.dev — the off-site backup target."))
P.append(stat("Hosts", 'sum(pve_up{id=~"node/.*"})', 12, 1,
              steps=[{"color": "red", "value": None}, {"color": "orange", "value": 2}, GREEN | {"value": 3}],
              desc="Proxmox hosts answering. Each carries one control plane."))
P.append(stat("K8s nodes", 'sum(kube_node_status_condition{condition="Ready",status="true"})', 15, 1,
              steps=[{"color": "red", "value": None}, {"color": "orange", "value": 2}, GREEN | {"value": 3}],
              desc="Ready nodes. Two is still a quorum; one is not."))
P.append(stat("ZFS pools", 'sum(node_zfs_zpool_state{state!="online"}) or vector(0)', 18, 1,
              mappings=[{"type": "value", "options": {"0": {"text": "Online", "color": "green", "index": 0}}}],
              steps=[GREEN, {"color": "red", "value": 1}], text_size=26,
              desc="Pools not ONLINE (degraded, faulted, suspended). Error counters on an online pool are sas-health-check.sh's job."))
P.append(stat("Stuck pods", 'sum(kube_pod_status_phase{phase=~"Pending|Failed|Unknown"}) or vector(0)', 21, 1,
              steps=[GREEN, {"color": "yellow", "value": 1}, {"color": "red", "value": 5}],
              desc="Pending, Failed or Unknown."))

# 2 -------------------------------------------- backups and certificates
# Ages and one countdown. Each tile answers "is this safety net still there".
P.append(row("Backups & certificates", 5))
P.append(age("Local backup",
             'max((time() - longhorn_volume_last_backup_at) and (longhorn_volume_last_backup_at != 0))',
             0, 6, warn=86400, crit=129600,
             desc=("Oldest last-backup among the Longhorn volumes that are backed up — to Garage on "
                   "pve-2, nightly at 23:50. Per-volume detail is in the Longhorn dashboard.")))
P.append(age("Off-site",
             'time() - max(backup_last_success_timestamp_seconds{leg="offsite"})',
             6, 6, warn=26 * 3600, crit=50 * 3600,
             desc=("Last completed restic push to Oracle, nightly at 03:10, append-only. This is the "
                   "copy that carries the Immich library, Nextcloud files and /media/photos. "
                   "Healthchecks.io alerts if it stops; this tile shows it.")))
P.append(age("VM image",
             'time() - max(backup_last_success_timestamp_seconds{leg="vm-image"})',
             12, 6, warn=8 * 86400, crit=10 * 86400,
             desc="Newest vzdump image of VM 1000 (Nextcloud), weekly on Saturday at 22:00."))
P.append(stat("Certificates", 'min(certmanager_certificate_expiration_timestamp_seconds - time())',
              18, 6, w=6, unit="s", decimals=1,
              steps=[{"color": "red", "value": None}, {"color": "yellow", "value": 86400},
                     GREEN | {"value": 172800}],
              desc=("Until the soonest certificate expires. Let's Encrypt shortlived: ~6.7 days, "
                    "renewed at ~2.2 days left, so anything above 2 days is normal.")))

# 3 ---------------------------------------------------------- kubernetes
# One tile per app, plus one for everything that is not an app. A workload
# deliberately scaled to 0 is left out (`> 0` on the desired count) - a
# disabled app is a decision in git, not an outage.
UP_MAP = [{"type": "value", "options": {
              "1": {"text": "Up", "color": "green", "index": 0},
              "0": {"text": "Down", "color": "red", "index": 1}}},
          {"type": "range", "options": {"from": 0.01, "to": 0.99,
              "result": {"text": "Degraded", "color": "orange", "index": 2}}}]

def broken(ns_sel):
    # count of workloads in these namespaces with fewer ready than desired
    return ("(count((kube_deployment_status_replicas_available{%s} / (kube_deployment_spec_replicas{%s} > 0)) < 1) or vector(0))"
            " + (count((kube_statefulset_status_replicas_ready{%s} / (kube_statefulset_replicas{%s} > 0)) < 1) or vector(0))"
            " + (count((kube_daemonset_status_number_ready{%s} / (kube_daemonset_status_desired_number_scheduled{%s} > 0)) < 1) or vector(0))"
            % ((ns_sel,) * 6))

P.append(row("Kubernetes", 10))
P.append(stat("CPU", 'sum(rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m])) / sum(kube_node_status_allocatable{resource="cpu"})',
              0, 11, w=4, unit="percentunit", decimals=0,
              steps=[GREEN, {"color": "yellow", "value": 0.7}, {"color": "red", "value": 0.9}],
              desc="Used by every container, against what the three nodes can allocate."))
P.append(stat("Memory", 'sum(container_memory_working_set_bytes{container!="",image!=""}) / sum(kube_node_status_allocatable{resource="memory"})',
              0, 15, w=4, unit="percentunit", decimals=0,
              steps=[GREEN, {"color": "yellow", "value": 0.75}, {"color": "red", "value": 0.9}],
              desc="Working set of every container, against allocatable memory. Working set is what the OOM killer counts."))
apps = stat("Apps", "", 4, 11, w=20, h=8,
            desc=("Ready against desired replicas for every app in the default namespace. "
                  "`platform` is everything else — Flux, Cilium, Longhorn, cert-manager, "
                  "observability, their DaemonSets included — Up only while none of it is short."))
apps["fieldConfig"]["defaults"]["mappings"] = UP_MAP
apps["fieldConfig"]["defaults"]["thresholds"]["steps"] = [{"color": "red", "value": None}, {"color": "orange", "value": 0.01}, GREEN | {"value": 1}]
apps["options"].update({"colorMode": "background_solid", "textMode": "value_and_name",
                        "orientation": "auto", "text": {"titleSize": 13, "valueSize": 15}})
apps["targets"] = [
    tgt('kube_deployment_status_replicas_available{namespace="default"} / (kube_deployment_spec_replicas{namespace="default"} > 0)',
        "{{deployment}}", instant=True, ref="A"),
    tgt('kube_statefulset_status_replicas_ready{namespace="default"} / (kube_statefulset_replicas{namespace="default"} > 0)',
        "{{statefulset}}", instant=True, ref="B"),
    tgt("(" + broken('namespace!="default"') + ") == bool 0", "platform", instant=True, ref="C"),
]
P.append(apps)

# 4 ------------------------------------------------------------ internet
P.append(row("Internet", 19))
P.append(stat("Download", "speedtest_download_bits_per_second" + OK, 0, 20, w=8, unit="bps", decimals=0,
              desc="Last Ookla speedtest. Runs every 4 h — each run moves ~1.8 GB."))
P.append(stat("Upload", "speedtest_upload_bits_per_second" + OK, 8, 20, w=8, unit="bps", decimals=0,
              desc="Last Ookla speedtest. Runs every 4 h — each run moves ~1.8 GB."))
P.append(stat("Round trip", "min(" + WAN_RTT + ")", 16, 20, w=8, unit="s", decimals=1,
              steps=[GREEN, {"color": "yellow", "value": 0.05}, {"color": "red", "value": 0.15}],
              desc="TCP handshake to the nearer of 1.1.1.1 / 8.8.8.8, measured constantly."))
P.append(ts("Throughput history", targets(
    ("speedtest_download_bits_per_second" + OK, "download"),
    ("speedtest_upload_bits_per_second" + OK, "upload")),
    0, 24, unit="bps", minv=0, step=True,
    desc="One point per test, every 4 h, so the line steps rather than curves."))
P.append(ts("Round trip history", targets((WAN_RTT, "{{instance}}")), 12, 24, unit="s", minv=0,
            desc="Gaps are outages: a failed probe has no round trip to plot."))

# 5 --------------------------------------------------------------- hosts
P.append(row("Hosts", 31))
P.append(ts("CPU", targets(
    ('pve_cpu_usage_ratio{id=~"node/.*"} * on(id, instance) group_left(name) pve_node_info', "{{name}}")),
    0, 32, w=8, h=8, unit="percentunit", minv=0, maxv=1))
P.append(ts("Memory", targets(
    ('(pve_memory_usage_bytes{id=~"node/.*"} / pve_memory_size_bytes{id=~"node/.*"}) '
     '* on(id, instance) group_left(name) pve_node_info', "{{name}}")),
    8, 32, w=8, h=8, unit="percentunit", minv=0, maxv=1))
P.append(bargauge("Temperature", 'max by (host) (node_hwmon_temp_celsius{job="pve-node"})', "{{host}}",
                  16, 32, w=8, h=8, unit="celsius", decimals=0, maxv=100,
                  steps=[GREEN, {"color": "yellow", "value": 70}, {"color": "red", "value": 85}],
                  desc="Hottest hwmon sensor per host — CPU cores and NVMe. The R730xd's fans follow drive temperature, not this."))
P.append(bargauge(
    "Storage fill",
    'sort_desc(pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"})',
    "{{id}}", 0, 40, maxv=1,
    steps=[GREEN, {"color": "yellow", "value": 0.8}, {"color": "red", "value": 0.9}],
    desc="Every Proxmox storage on every host. PveStorageNearFull fires at 80 %, Critical at 90 %."))
P.append(bargauge(
    "SSD wear",
    ('sort_desc(label_replace(nvme_percentage_used_ratio{job="pve-node"}, "disk", "", "device", "(.*)") '
     'or ((100 - smartmon_media_wearout_indicator_value{job="pve-node", type="sat"}) / 100))'),
    "{{host}} {{disk}}", 12, 40, maxv=1,
    steps=[GREEN, {"color": "yellow", "value": 0.6}, {"color": "red", "value": 0.8}],
    desc=("Rated endurance used. pve-1's nvme1n1 is the QLC drive that took 3.5x write "
          "amplification under a ZFS zvol until 2026-09-07 — the one to watch. SAS disks are "
          "not here: they are parked, and sas-health-check.sh reads them nightly.")))

# 6 --------------------------------------------------------------- power
R730 = 'node_ipmi_power_watts{sensor="Pwr Consumption"}'
P.append(row("Power — CyberPower VP700ELCD", 48))
P.append(stat("Battery", "network_ups_tools_battery_charge", 0, 49, w=6, unit="percent", decimals=0,
              steps=[{"color": "red", "value": None}, {"color": "yellow", "value": 40}, GREEN | {"value": 90}]))
P.append(stat("Runtime left", "network_ups_tools_battery_runtime", 6, 49, w=6, unit="s", decimals=0,
              steps=[{"color": "red", "value": None}, {"color": "yellow", "value": 360}, GREEN | {"value": 480}],
              desc="NUT shuts every host down at 300 s (battery.runtime.low)."))
P.append(stat("Estate draw", DRAW, 12, 49, w=6, unit="watt", decimals=0,
              steps=[GREEN, {"color": "yellow", "value": 280}, {"color": "red", "value": 330}],
              desc="Everything behind the UPS. Derived: it reports load only as a percentage of 390 W."))
P.append(stat("R730xd", R730, 18, 49, w=6, unit="watt", decimals=0, steps=[GREEN],
              desc="PSU reading from iDRAC. 112 W is the tuned baseline with the SAS disks parked."))
P.append(ts("Draw history", targets((DRAW, "estate (UPS)"), (R730, "R730xd (iDRAC)")),
            0, 53, unit="watt", decimals=0, minv=0,
            desc="The gap between the two lines is pve-1, pve-3 and the switch."))
P.append(ts("Runtime history", targets(("network_ups_tools_battery_runtime", "runtime")),
            12, 53, unit="s", minv=0,
            desc="Estimated on mains. Drifting down over months is how the battery announces its age."))

dash = {
    "annotations": {"list": [{
        "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts", "type": "dashboard"}]},
    "editable": True, "graphTooltip": 1, "links": [], "panels": P,
    "refresh": "1m", "schemaVersion": 39, "tags": ["homelab"],
    "templating": {"list": []}, "time": {"from": "now-24h", "to": "now"},
    "timepicker": {}, "timezone": "browser", "title": "Homelab Overview",
    "uid": "homelab-overview", "version": 4, "weekStart": ""}

# refuse to emit the bug that prompted this rewrite
for p in P:
    refs = [t["refId"] for t in p.get("targets", [])]
    assert len(refs) == len(set(refs)), f"duplicate refId in {p['title']}"

out = Path(__file__).with_suffix(".json")
out.write_text(json.dumps(dash, indent=2) + "\n")
print(f"wrote {out.name}: {len(P)} panels, version {dash['version']}")

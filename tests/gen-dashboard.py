#!/usr/bin/env python3
"""Generates deploy/monitoring/dashboards/mts-demo-overview.json.

The dashboard is kept as generated JSON (what Grafana consumes); this script is
the readable source. Run: python3 tests/gen-dashboard.py
"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "prometheus"}
LOGS = {"type": "victoriametrics-logs-datasource", "uid": "victorialogs"}
ROUTES = 'envoy_cluster_name=~"httproute/demo/.*"'

panels = []
_y = 0


def row(title):
    global _y
    panels.append({"type": "row", "title": title, "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y}, "id": len(panels) + 1})
    _y += 1


def ts(title, targets, x, w, h=8, unit="short", stack=False, desc=""):
    panels.append({
        "type": "timeseries", "title": title, "description": desc, "id": len(panels) + 1,
        "datasource": PROM, "gridPos": {"h": h, "w": w, "x": x, "y": _y},
        "fieldConfig": {"defaults": {"unit": unit, "custom": {
            "drawStyle": "line", "lineWidth": 1, "fillOpacity": 15 if stack else 0,
            "stacking": {"mode": "normal" if stack else "none"}}}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi"}},
        "targets": [{"refId": chr(65 + i), "datasource": PROM, "expr": e, "legendFormat": l}
                    for i, (e, l) in enumerate(targets)],
    })


def stat(title, expr, x, w, unit="short", thresholds=None, h=4):
    panels.append({
        "type": "stat", "title": title, "id": len(panels) + 1, "datasource": PROM,
        "gridPos": {"h": h, "w": w, "x": x, "y": _y},
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": thresholds or {
            "mode": "absolute", "steps": [{"color": "green", "value": None}]}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "targets": [{"refId": "A", "datasource": PROM, "expr": expr}],
    })


def nl(h):
    global _y
    _y += h


row("Gateway API (Envoy) - traffic to the demo app")
stat("Requests/s", f"sum(rate(envoy_cluster_upstream_rq_total{{{ROUTES}}}[1m]))", 0, 6, "reqps")
stat("5xx ratio (5m)", "mts:gateway_5xx_ratio:rate5m", 6, 6, "percentunit",
     {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.01},
                                    {"color": "red", "value": 0.05}]})
stat("p95 latency (5m)", "mts:gateway_latency_ms:p95_5m", 12, 6, "ms",
     {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 200},
                                    {"color": "red", "value": 500}]})
stat("Rate-limited (429) /s",
     'sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="4"}[1m]))', 18, 6, "reqps")
nl(4)
ts("Requests/s by response code class",
   [(f"sum by (envoy_response_code_class) (rate(envoy_cluster_upstream_rq_xx{{{ROUTES}}}[1m]))",
     "{{envoy_response_code_class}}xx")], 0, 12, unit="reqps", stack=True)
ts("Requests/s by route / backend (traffic split)",
   [(f"sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total{{{ROUTES}}}[1m]))",
     "{{envoy_cluster_name}}")], 12, 12, unit="reqps", stack=True)
nl(8)
ts("Upstream latency percentiles",
   [(f"histogram_quantile({q}, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{{{ROUTES}}}[5m])))",
     f"p{int(q * 100)}") for q in (0.5, 0.95, 0.99)], 0, 12, unit="ms")
ts("Requests/s by HTTP status code",
   [(f"sum by (envoy_response_code) (rate(envoy_cluster_upstream_rq{{{ROUTES}}}[1m]))",
     "{{envoy_response_code}}")], 12, 12, unit="reqps")
nl(8)

row("Application (nginx)")
stat("Ready pods", 'sum(kube_deployment_status_replicas_available{namespace="demo"})', 0, 6)
stat("nginx up", 'sum(nginx_up{namespace="demo"})', 6, 6)
stat("Active connections", 'sum(nginx_connections_active{namespace="demo"})', 12, 6)
stat("Requests/s (nginx)", 'sum(rate(nginx_http_requests_total{namespace="demo"}[1m]))', 18, 6, "reqps")
nl(4)
ts("nginx requests/s per pod",
   [('sum by (pod) (rate(nginx_http_requests_total{namespace="demo"}[1m]))', "{{pod}}")], 0, 8, unit="reqps")
ts("CPU per pod (cores)",
   [('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo", container!=""}[2m]))', "{{pod}}")],
   8, 8)
ts("Memory per pod (working set)",
   [('sum by (pod) (container_memory_working_set_bytes{namespace="demo", container!=""})', "{{pod}}")],
   16, 8, unit="bytes")
nl(8)

row("Logging (Fluentd -> VictoriaLogs)")
ts("Fluentd records/s (in -> out)",
   [('sum(rate(fluentd_input_status_num_records_total[1m]))', "input"),
    ('sum(rate(fluentd_output_status_emit_records{plugin_id="out_victorialogs"}[1m]))', "output (VictoriaLogs)")], 0, 8, unit="short")
ts("Fluentd buffer / retries",
   [('sum(fluentd_output_status_buffer_queue_length)', "queue length"),
    ('sum(fluentd_output_status_retry_count)', "retries"),
    ('sum(increase(fluentd_output_status_num_errors[5m]))', "errors (5m)")], 8, 8)
ts("Node CPU / memory utilisation",
   [('1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))', "CPU"),
    ('1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)', "Memory")],
   16, 8, unit="percentunit")
nl(8)
panels.append({
    "type": "logs", "title": "Demo app logs (VictoriaLogs, LogsQL)", "id": len(panels) + 1,
    "datasource": LOGS, "gridPos": {"h": 12, "w": 24, "x": 0, "y": _y},
    "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending"},
    "targets": [{"refId": "A", "datasource": LOGS,
                 "expr": 'kubernetes.namespace_name:demo | sort by (_time desc) | limit 200'}],
})

dashboard = {
    "uid": "mts-demo-overview", "title": "MTS Demo - Gateway, App & Logs overview",
    "tags": ["mts-demo", "gateway-api", "envoy", "nginx", "fluentd"],
    "timezone": "browser", "schemaVersion": 39, "version": 1, "editable": True,
    "refresh": "10s", "time": {"from": "now-30m", "to": "now"},
    "panels": panels, "templating": {"list": []}, "annotations": {"list": []},
}

out = pathlib.Path(__file__).resolve().parent.parent / "deploy/monitoring/dashboards/mts-demo-overview.json"
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"written {out}")

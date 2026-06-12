# kubernetes/monitoring/ — Observability Stack

Monitoring and observability services for the cluster.

---

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| **kube-prometheus-stack** | `https://grafana.int.${BASE_DOMAIN}` | Prometheus + Grafana + Alertmanager |
| **loki** | — | Log aggregation |
| **alerts** | — | PrometheusRule alert definitions |

---

## Accessing Grafana

Open: `https://grafana.int.${BASE_DOMAIN}` (behind Authentik forward-auth)

Default dashboards:
- Kubernetes cluster overview
- Node resource usage
- Pod CPU/memory
- Longhorn storage

---

## Adding Custom Dashboards

Add a ConfigMap with `grafana_dashboard: "1"` label in the `monitoring` namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { ... Grafana dashboard JSON ... }
```

---

## Adding Alert Rules

Add a `PrometheusRule` in `kubernetes/monitoring/alerts/manifests/`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-alerts
  namespace: monitoring
spec:
  groups:
    - name: my-app
      rules:
        - alert: MyAppDown
          expr: up{job="my-app"} == 0
          for: 5m
```

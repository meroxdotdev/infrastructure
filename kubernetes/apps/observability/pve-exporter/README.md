# pve-exporter

Scrapes the Proxmox API of every host in the estate. One deployment, one
target per host, selected per scrape by the `module` query parameter — the
same blackbox pattern `blackbox-exporter` and `nut-exporter` use.

The hosts are **standalone**, not a corosync cluster. There is no shared
authentication and no host that can answer for another, so each one needs its
own API token and its own section in `pve.yml`.

| Host | Address | Module in `pve.yml` |
|---|---|---|
| `pve-2` R730xd | `10.57.57.250` | `default` |
| `pve-1` Beelink | `10.57.57.254` | `pve-1` |
| `pve-3` OptiPlex | `10.57.57.253` | `pve-3` |

`pve-2`'s module is called `default` because it was the only one when this was
built. Renaming it would break the live scrape for no gain; new hosts are
named after themselves.

## Adding a host

Until 2026-09-11 only `pve-2` was scraped, so `PveNodeDown`, `PveHostHighCpu`
and the storage alerts covered one host out of three — while all three carry a
control plane. The ScrapeConfigs for `pve-1` and `pve-3` are now in
[`../kube-prometheus-stack/app/scrapeconfig.yaml`](../kube-prometheus-stack/app/scrapeconfig.yaml).

**Do the token and the secret first.** A ScrapeConfig whose module does not
exist in `pve.yml` fails every scrape, and no alert fires on that — it is only
a red target in Prometheus, which is exactly the kind of quiet failure this
repo tries not to create.

On the new host, as root — read-only, `PVEAuditor` and nothing more:

```bash
pveum user add prometheus@pve --comment "pve-exporter, read-only"
pveum aclmod / --users prometheus@pve --roles PVEAuditor
pveum user token add prometheus@pve prometheus --privsep 0
# prints the token value ONCE - copy it now
```

Then add the module to the secret, from a checkout with the age key:

```bash
sops edit kubernetes/apps/observability/pve-exporter/app/secret.sops.yaml
```

```yaml
pve-1:
    user: prometheus@pve
    token_name: prometheus
    token_value: <the value printed above>
    verify_ssl: false
```

`verify_ssl: false` because these hosts serve the Proxmox default
self-signed certificate.

The pod picks the change up on its own: Reloader restarts it when the Secret
changes. Without that it would not — `pve.yml` is a `subPath` mount, and those
never receive updates.

Verify from inside the cluster once Flux has reconciled:

```bash
kubectl -n observability port-forward svc/pve-exporter 9221:9221
curl -s 'http://localhost:9221/pve?module=pve-1&target=10.57.57.254' | grep '^pve_up'
```

Every `pve_up` should be `1`. An empty response or a `pve_error` means the
module name in the ScrapeConfig and the key in `pve.yml` do not match.

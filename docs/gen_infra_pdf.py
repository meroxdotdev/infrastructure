#!/usr/bin/env python3
"""Generate professional infrastructure overview PDF - v3 (graphviz diagrams)"""

import graphviz
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import base64, io, weasyprint

# ── helpers ──────────────────────────────────────────────────────────────────

def png_b64(path):
    with open(path, 'rb') as f:
        return base64.b64encode(f.read()).decode()

def fig_b64(fig):
    buf = io.BytesIO()
    fig.savefig(buf, format='png', dpi=180, bbox_inches='tight',
                facecolor='white', edgecolor='none')
    plt.close(fig)
    buf.seek(0)
    return base64.b64encode(buf.read()).decode()

# ── diagram 1 : architecture topology ────────────────────────────────────────

def diag_arch():
    g = graphviz.Digraph('arch', format='png')
    g.attr(rankdir='TB', splines='spline', compound='true',
           bgcolor='white', fontname='Helvetica', dpi='180',
           size='8,6.5', pad='0.4', nodesep='0.45', ranksep='0.6')
    g.attr('node', fontname='Helvetica', fontsize='10',
           style='rounded,filled', shape='box', margin='0.18,0.10')
    g.attr('edge', fontname='Helvetica', fontsize='8', color='#546e7a')

    # top row
    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('internet', 'Internet / Users', shape='ellipse',
               fillcolor='#eceff1', color='#90a4ae')
        s.node('github', 'GitHub\nmeroxdotdev/infrastructure',
               fillcolor='#fafafa', color='#37474f', penwidth='1.5')

    # cloudflare + tailscale
    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('cf',
               'Cloudflare\nTunnel  ·  DNS  ·  WAF  ·  Pages',
               fillcolor='#fff3e0', color='#f57c00', penwidth='2')
        s.node('ts',
               'Tailscale VPN\nMesh  ·  MagicDNS  ·  Exit node',
               fillcolor='#e8f5e9', color='#388e3c', penwidth='2')

    # VPS cluster
    with g.subgraph(name='cluster_vps') as c:
        c.attr(label='Oracle Cloud VPS  —  4 vCPU ARM  ·  24 GB RAM  ·  €0/mo',
               style='filled,rounded', fillcolor='#e3f2fd',
               color='#1565c0', penwidth='2.5',
               fontsize='10', fontname='Helvetica', labeljust='l')
        c.node('traefik',  'Traefik\n(reverse proxy · TLS)',
               fillcolor='#bbdefb', color='#0d47a1')
        c.node('auth_vps', 'Authentik SSO\n(Google-only)',
               fillcolor='white', color='#0d47a1')
        c.node('pihole',   'Pi-hole + Unbound\n(DNS · DoH · ad-block)',
               fillcolor='white', color='#0d47a1')
        c.node('garage',   'Garage S3\n(Longhorn backup target)',
               fillcolor='#fff3e0', color='#e65100')
        c.node('vps_mon',  'Netdata  ·  Beszel  ·  Dozzle\nUptime Kuma  ·  Glances',
               fillcolor='white', color='#0d47a1')
        c.node('openclaw', 'OpenClaw AI Agents\n(Telegram  ·  Claude API)',
               fillcolor='#ede7f6', color='#6a1b9a')

    # K8s cluster
    with g.subgraph(name='cluster_k8s') as c:
        c.attr(label='Kubernetes Cluster  —  3× Talos Linux nodes on Proxmox',
               style='filled,rounded', fillcolor='#f3e5f5',
               color='#7b1fa2', penwidth='2.5',
               fontsize='10', fontname='Helvetica', labeljust='l')
        c.node('cilium',    'Cilium  ·  cert-manager\nk8s-gateway  ·  CF Tunnel agent',
               fillcolor='white', color='#7b1fa2')
        c.node('longhorn',  'Longhorn\n(distributed block storage)',
               fillcolor='#e3f2fd', color='#1565c0')
        c.node('flux',      'FluxCD v2\n(GitOps — pulls every 1 min)',
               fillcolor='#e8f5e9', color='#2e7d32')
        c.node('media',     'Jellyfin  ·  Radarr  ·  Sonarr\nProwlarr  ·  qBittorrent  ·  Jellyseerr',
               fillcolor='white', color='#7b1fa2')
        c.node('obs',       'Prometheus  ·  Grafana  ·  Loki\nAlertManager  ·  Promtail',
               fillcolor='white', color='#7b1fa2')
        c.node('apps',      'n8n  ·  Authentik outpost\nPortainer agent',
               fillcolor='white', color='#7b1fa2')

    # Home network
    with g.subgraph(name='cluster_home') as c:
        c.attr(label='Home Network',
               style='filled,rounded', fillcolor='#f9fbe7',
               color='#558b2f', penwidth='1.5',
               fontsize='10', fontname='Helvetica')
        c.node('nas',      'Synology DS223+\nNFS  ·  RAID1  ·  10.57.57.201',
               fillcolor='white', color='#558b2f')
        c.node('pfsense',  'pfSense  (XCY X44)\nFirewall  ·  DHCP  ·  Routing',
               fillcolor='white', color='#ef6c00')

    # ── edges ──
    g.edge('internet', 'cf',      color='#f57c00', penwidth='2',   label=' HTTPS')
    g.edge('cf',  'traefik',      color='#f57c00', style='dashed', label=' Tunnel',
           lhead='cluster_vps',  penwidth='1.8')
    g.edge('cf',  'cilium',       color='#f57c00', style='dashed', label=' Tunnel',
           lhead='cluster_k8s',  penwidth='1.8')
    g.edge('ts',  'traefik',      color='#388e3c', style='dashed', label=' mgmt VPN',
           lhead='cluster_vps')
    g.edge('ts',  'cilium',       color='#388e3c', style='dashed', label=' mgmt VPN',
           lhead='cluster_k8s')
    g.edge('longhorn', 'garage',  color='#e65100', penwidth='2.5',
           label=' S3 backup\n (daily 02:00 · Tailscale)')
    g.edge('nas',      'media',   color='#558b2f', label=' NFS',
           lhead='cluster_k8s')
    g.edge('github',   'flux',    color='#2e7d32', style='dashed',
           label=' GitOps pull', lhead='cluster_k8s')

    out = g.render('/tmp/diag_arch', cleanup=True)
    return png_b64(out)


# ── diagram 2 : gitops pipeline ───────────────────────────────────────────────

def diag_gitops():
    g = graphviz.Digraph('gitops', format='png')
    g.attr(rankdir='LR', splines='spline', bgcolor='white',
           fontname='Helvetica', dpi='180', size='8,2.8',
           pad='0.3', nodesep='0.5', ranksep='0.65')
    g.attr('node', fontname='Helvetica', fontsize='10',
           style='rounded,filled', shape='box', margin='0.2,0.12')
    g.attr('edge', fontname='Helvetica', fontsize='8.5')

    g.node('dev',   'Developer\nworkstation',
           fillcolor='#e8f5e9', color='#388e3c')
    g.node('gh',    'GitHub\nmeroxdotdev/infrastructure',
           fillcolor='#fafafa', color='#37474f', penwidth='1.5')
    g.node('renovate', 'Renovate Bot\n(auto PRs weekly)',
           fillcolor='#fff8e1', color='#f57c00', style='rounded,filled,dashed')

    with g.subgraph(name='cluster_flux') as c:
        c.attr(label='FluxCD v2  (running inside K8s cluster)',
               style='filled,rounded', fillcolor='#e3f2fd',
               color='#1565c0', penwidth='2', fontsize='10')
        c.node('src',  'Source\nController',  fillcolor='#bbdefb', color='#0d47a1')
        c.node('kust', 'Kustomize\nController', fillcolor='white', color='#0d47a1')
        c.node('helm', 'Helm\nController',    fillcolor='white', color='#0d47a1')

    with g.subgraph(name='cluster_sops') as c:
        c.attr(label='SOPS / AGE decryption', style='rounded,filled',
               fillcolor='#fce4ec', color='#c62828', penwidth='1.5', fontsize='10')
        c.node('sops', '*.sops.yaml\n→ plaintext secrets',
               fillcolor='white', color='#c62828')

    with g.subgraph(name='cluster_cluster') as c:
        c.attr(label='K8s cluster state', style='filled,rounded',
               fillcolor='#f3e5f5', color='#7b1fa2', penwidth='2', fontsize='10')
        c.node('wl', 'Running\nworkloads',   fillcolor='white', color='#7b1fa2')
        c.node('hr', 'HelmReleases\napplied', fillcolor='white', color='#7b1fa2')

    g.edge('dev',      'gh',    label=' git push', color='#388e3c', penwidth='2')
    g.edge('renovate', 'gh',    label=' auto PRs', color='#f57c00', style='dashed')
    g.edge('gh',       'src',   label=' poll (1 min)', color='#1565c0', penwidth='1.8',
           lhead='cluster_flux')
    g.edge('src',  'kust',  color='#1565c0')
    g.edge('src',  'helm',  color='#1565c0')
    g.edge('kust', 'sops',  color='#c62828', style='dashed', label=' decrypt')
    g.edge('sops', 'wl',    color='#7b1fa2', lhead='cluster_cluster')
    g.edge('helm', 'hr',    color='#7b1fa2', lhead='cluster_cluster')

    out = g.render('/tmp/diag_gitops', cleanup=True)
    return png_b64(out)


# ── diagram 3 : storage & backup ─────────────────────────────────────────────

def diag_storage():
    g = graphviz.Digraph('storage', format='png')
    g.attr(rankdir='TB', splines='spline', bgcolor='white',
           fontname='Helvetica', dpi='180', size='7.5,4',
           pad='0.3', nodesep='0.5', ranksep='0.55')
    g.attr('node', fontname='Helvetica', fontsize='10',
           style='rounded,filled', shape='box', margin='0.18,0.10')
    g.attr('edge', fontname='Helvetica', fontsize='8.5')

    # App pods row
    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('jellyfin',  'Jellyfin',     fillcolor='#e8eaf6', color='#3949ab')
        s.node('arr',       'Radarr\nSonarr', fillcolor='#e8eaf6', color='#3949ab')
        s.node('prom',      'Prometheus\nGrafana', fillcolor='#e8eaf6', color='#3949ab')
        s.node('n8n_pod',   'n8n\nautomatizare', fillcolor='#e8eaf6', color='#3949ab')
        s.node('auth_pod',  'Authentik\nJoplin DB', fillcolor='#e8eaf6', color='#3949ab')

    # Storage layer
    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('longhorn2', 'Longhorn\n(block · 3-way replica)',
               fillcolor='#e3f2fd', color='#1565c0', penwidth='2')
        s.node('nfs',       'Synology NAS\n(NFS · media files)',
               fillcolor='#e8f5e9', color='#388e3c', penwidth='2')

    # Backup layer
    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('garage2',   'Garage S3\n(Oracle Cloud VPS)\noff-site object store',
               fillcolor='#fff3e0', color='#e65100', penwidth='2')
        s.node('dbbackup',  'pg_dump backups\n/srv/backups/\n(Authentik · Joplin · 7 days)',
               fillcolor='#fce4ec', color='#c62828', penwidth='2')

    # edges: pods -> storage
    for src in ['jellyfin', 'arr', 'prom', 'n8n_pod']:
        g.edge(src, 'longhorn2', color='#1565c0', arrowsize='0.7')
    g.edge('auth_pod',  'dbbackup',  color='#c62828', label=' pg_dump\n (cron)', arrowsize='0.7')
    g.edge('jellyfin',  'nfs',       color='#388e3c', label=' NFS\n (media)', arrowsize='0.7')
    g.edge('arr',       'nfs',       color='#388e3c', arrowsize='0.7')

    # storage -> backup
    g.edge('longhorn2', 'garage2',
           color='#e65100', penwidth='2.5',
           label=' S3 API over Tailscale\n daily backup at 02:00')

    out = g.render('/tmp/diag_storage', cleanup=True)
    return png_b64(out)


# ── diagram 4 : network access paths ─────────────────────────────────────────

def diag_network():
    g = graphviz.Digraph('net', format='png')
    g.attr(rankdir='TB', splines='spline', bgcolor='white',
           fontname='Helvetica', dpi='180', size='6,4.2',
           pad='0.3', nodesep='0.6', ranksep='0.55')
    g.attr('node', fontname='Helvetica', fontsize='10',
           style='rounded,filled', shape='box', margin='0.18,0.10')
    g.attr('edge', fontname='Helvetica', fontsize='8.5')

    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('pub',  'Public User\n(browser / app)',
               shape='ellipse', fillcolor='#eceff1', color='#90a4ae')
        s.node('admin','Admin / Me\n(Tailscale device)',
               shape='ellipse', fillcolor='#e8f5e9', color='#388e3c')

    s.attr(rank='same')
    g.node('cf2',  'Cloudflare Edge\nDNS  ·  WAF  ·  DDoS protection',
           fillcolor='#fff3e0', color='#f57c00', penwidth='2')
    g.node('ts2',  'Tailscale\nMesh VPN  ·  100.x.x.x',
           fillcolor='#e8f5e9', color='#388e3c', penwidth='2')

    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('traefik2', 'Traefik (VPS)\nTLS termination',
               fillcolor='#bbdefb', color='#0d47a1')
        s.node('cftunnel', 'CF Tunnel agent\n(pod in K8s)',
               fillcolor='#f3e5f5', color='#7b1fa2')

    with g.subgraph() as s:
        s.attr(rank='same')
        s.node('vps_svc',  'VPS services\n(Docker containers)',
               fillcolor='#e3f2fd', color='#1565c0')
        s.node('k8s_svc',  'K8s services\n(via Cilium L2 LB)',
               fillcolor='#f3e5f5', color='#7b1fa2')
        s.node('mgmt',     'Portainer EE  ·  Homepage\n(Tailscale-only access)',
               fillcolor='#e8f5e9', color='#388e3c')

    g.node('pihole2', 'Pi-hole + Unbound\nDNS resolver  ·  ad-block',
           fillcolor='#e3f2fd', color='#0d47a1')
    g.node('k8sgw',   'k8s-gateway\nSplit-horizon DNS\n*.merox.dev → LAN IPs',
           fillcolor='#ede7f6', color='#6a1b9a', style='rounded,filled,dashed')

    g.edge('pub',   'cf2',      color='#f57c00', penwidth='2',  label=' HTTPS / 443')
    g.edge('admin', 'ts2',      color='#388e3c', penwidth='2',  label=' WireGuard VPN')
    g.edge('cf2',   'traefik2', color='#f57c00', style='dashed', label=' Tunnel (outbound only\n no open ports)')
    g.edge('cf2',   'cftunnel', color='#f57c00', style='dashed')
    g.edge('ts2',   'traefik2', color='#388e3c', style='dashed', label=' 100.x.x.x')
    g.edge('ts2',   'mgmt',     color='#388e3c', style='dashed')
    g.edge('traefik2', 'vps_svc', color='#1565c0')
    g.edge('cftunnel', 'k8s_svc', color='#7b1fa2')
    g.edge('ts2',   'pihole2',  color='#0d47a1', style='dashed', label=' DNS queries')
    g.edge('pihole2','k8sgw',   color='#6a1b9a', style='dashed', label=' forward *.merox.dev')

    out = g.render('/tmp/diag_network', cleanup=True)
    return png_b64(out)


# ── chart : cost breakdown ────────────────────────────────────────────────────

def chart_costs():
    fig, ax = plt.subplots(figsize=(7.5, 2.6))
    fig.patch.set_facecolor('white')

    services = [
        'Hetzner VPS\n(fallback, on-demand)',
        'Claude Pro\n(AI agents)',
        'GitHub / Let\'s Encrypt\n/ Cloudflare / Tailscale',
        'Oracle Cloud VPS\n(always-free tier)',
    ]
    costs  = [5.39, 20.0, 0.0, 0.0]
    colors = ['#ffcc80', '#90caf9', '#a5d6a7', '#a5d6a7']
    labels = ['€5.39/mo\n(optional)', '~$20/mo', '€0', '€0']

    bars = ax.barh(services, costs, color=colors, edgecolor='#e0e0e0',
                   linewidth=0.8, height=0.55)
    ax.set_xlim(0, 26)
    ax.set_xlabel('Cost (€ or $ / month)', fontsize=9, color='#555')
    ax.tick_params(axis='y', labelsize=9)
    ax.tick_params(axis='x', labelsize=8)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    ax.set_title('Monthly Infrastructure Cost Breakdown', fontsize=11,
                 fontweight='bold', pad=8, color='#1a237e')

    for bar, label in zip(bars, labels):
        w = bar.get_width()
        ax.text(w + 0.4, bar.get_y() + bar.get_height() / 2,
                label, va='center', fontsize=8.5, color='#333')

    ax.axvline(x=0.15, color='#bbb', linewidth=0.8, linestyle='--')
    fig.tight_layout()
    return fig_b64(fig)


# ── generate all assets ───────────────────────────────────────────────────────

print("Generating diagrams...")
D_ARCH    = diag_arch()
D_GITOPS  = diag_gitops()
D_STORAGE = diag_storage()
D_NETWORK = diag_network()
C_COSTS   = chart_costs()
print("Diagrams done.")


# ── html ──────────────────────────────────────────────────────────────────────

HTML = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<style>
/* ── reset ── */
* {{ box-sizing: border-box; margin: 0; padding: 0; }}

/* ── pages ── */
@page       {{ size: A4; margin: 0; }}
@page cover {{ size: A4; margin: 0; }}
@page body  {{
  size: A4;
  margin: 18mm 17mm 20mm 17mm;
  @bottom-center {{
    content: "Robert Melcher  ·  HPC System Administrator @ Forvia  ·  merox.dev";
    font-size: 7pt; color: #999;
    font-family: Helvetica, Arial, sans-serif;
  }}
  @bottom-right {{
    content: counter(page);
    font-size: 7pt; color: #bbb;
    font-family: Helvetica, Arial, sans-serif;
  }}
}}

body {{
  font-family: Helvetica, Arial, sans-serif;
  font-size: 9.5pt;
  color: #2d2d2d;
  line-height: 1.5;
}}

/* ── cover ── */
.cover {{
  page: cover;
  width: 210mm; height: 297mm;
  background: #0d1b2a;
  position: relative;
  overflow: hidden;
}}
.cover-bg1 {{
  position: absolute; top: 0; right: 0;
  width: 120mm; height: 120mm;
  background: radial-gradient(circle at top right,
    rgba(41,182,246,.22), transparent 68%);
}}
.cover-bg2 {{
  position: absolute; bottom: 0; left: 0;
  width: 100mm; height: 80mm;
  background: radial-gradient(circle at bottom left,
    rgba(233,69,96,.14), transparent 70%);
}}
.cover-stripe {{
  position: absolute; top: 0; left: 0;
  width: 8mm; height: 297mm;
  background: linear-gradient(180deg, #29b6f6, #e94560);
}}
.cover-body {{
  position: absolute;
  top: 56mm; left: 22mm; right: 18mm;
}}
.cover-tag {{
  font-size: 7.5pt; font-weight: 700; letter-spacing: 3px;
  text-transform: uppercase; color: #29b6f6; margin-bottom: 8mm;
}}
.cover-title {{
  font-size: 34pt; font-weight: 800; color: #fff;
  line-height: 1.12; margin-bottom: 4mm;
}}
.cover-subtitle {{
  font-size: 13pt; font-weight: 300; color: #90caf9; margin-bottom: 12mm;
}}
.cover-divider {{
  width: 38mm; height: 3px;
  background: linear-gradient(90deg, #29b6f6, #e94560);
  margin-bottom: 10mm; border-radius: 2px;
}}
.cover-name {{
  font-size: 12pt; font-weight: 700; color: #eceff1; margin-bottom: 2mm;
}}
.cover-role {{
  font-size: 9.5pt; color: #80cbc4; margin-bottom: 6mm;
}}
.cover-date {{ font-size: 8pt; color: #607d8b; }}
.cover-stats {{
  position: absolute; bottom: 20mm; left: 22mm; right: 18mm;
  display: flex; gap: 6mm;
}}
.stat {{
  text-align: center;
  background: rgba(255,255,255,.07);
  border: 1px solid rgba(255,255,255,.13);
  border-radius: 6px; padding: 5mm 6mm; flex: 1;
}}
.stat-n {{ font-size: 20pt; font-weight: 800; color: #29b6f6; display: block; }}
.stat-l {{ font-size: 6.5pt; color: #90caf9; text-transform: uppercase;
           letter-spacing: 1px; display: block; margin-top: 1mm; }}

/* ── content page ── */
.page {{ page: body; page-break-before: always; }}

/* ── section header ── */
.sh {{
  display: flex; align-items: center; gap: 4mm;
  border-bottom: 2.5px solid #1b3a6b;
  padding-bottom: 3mm; margin-bottom: 5mm;
}}
.sh-dot {{
  width: 6mm; height: 6mm; flex-shrink: 0; border-radius: 3px;
  background: linear-gradient(135deg,#1b3a6b,#29b6f6);
}}
h1.sh-title {{ font-size: 15pt; font-weight: 800; color: #0d1b2a; line-height: 1; }}

h2 {{
  font-size: 10.5pt; font-weight: 700; color: #1b3a6b;
  margin: 5mm 0 2.5mm 0;
  border-left: 3px solid #29b6f6; padding-left: 3mm;
}}
h3 {{ font-size: 9.5pt; font-weight: 700; color: #0d1b2a; margin: 3mm 0 1.5mm 0; }}
p  {{ margin-bottom: 2.5mm; font-size: 9pt; }}

/* ── tables ── */
table {{
  width: 100%; border-collapse: collapse;
  font-size: 8.5pt; margin-bottom: 4mm;
  page-break-inside: avoid;
}}
thead tr {{ background: #1b3a6b; color: #fff; }}
thead th {{
  padding: 2.5mm 3mm; text-align: left;
  font-weight: 700; font-size: 8pt; letter-spacing: .2px;
}}
tbody tr:nth-child(even) {{ background: #f0f4ff; }}
tbody tr:nth-child(odd)  {{ background: #fafbff; }}
tbody td {{
  padding: 2mm 3mm;
  border-bottom: 1px solid #dde4f0;
  vertical-align: top;
  line-height: 1.5;
}}
td.url {{ color: #1565c0; font-size: 7.5pt; }}

/* ── badges ── */
.b {{ display: inline-block; padding: 0.3mm 2.2mm; border-radius: 3px;
      font-size: 7pt; font-weight: 700; }}
.b-blue   {{ background:#e3f2fd; color:#1565c0; }}
.b-green  {{ background:#e8f5e9; color:#2e7d32; }}
.b-orange {{ background:#fff3e0; color:#e65100; }}
.b-red    {{ background:#fce4ec; color:#c62828; }}
.b-purple {{ background:#f3e5f5; color:#6a1b9a; }}
.b-teal   {{ background:#e0f2f1; color:#00695c; }}
.b-gray   {{ background:#f5f5f5; color:#555;    }}

/* ── callouts ── */
.callout {{
  border-left: 4px solid #29b6f6; background: #e3f2fd;
  padding: 3mm 4mm; margin: 3mm 0; border-radius: 0 5px 5px 0;
  font-size: 8.5pt; page-break-inside: avoid;
}}
.callout.warn  {{ border-left-color: #ff9800; background: #fff8e1; }}
.callout.danger{{ border-left-color: #e94560; background: #fce4ec; }}
.callout strong{{ display: block; font-size: 7.5pt; text-transform: uppercase;
                  letter-spacing: .5px; margin-bottom: 1mm; color: #1565c0; }}
.callout.warn  strong{{ color:#e65100; }}
.callout.danger strong{{ color:#c62828; }}

/* ── code ── */
pre {{
  background: #1e2a3a; color: #cdd9e5;
  border-radius: 5px; padding: 3.5mm 4mm;
  font-family: 'Courier New', monospace; font-size: 7.5pt; line-height: 1.6;
  margin: 2mm 0 4mm 0; page-break-inside: avoid; white-space: pre-wrap;
}}
code {{
  background: #e8edf5; color: #1b3a6b;
  padding: .3mm 1.5mm; border-radius: 3px;
  font-family: 'Courier New', monospace; font-size: 8pt;
}}

/* ── two-column ── */
.two-col {{ overflow: hidden; margin-bottom: 4mm; }}
.col-l   {{ float: left;  width: 48%; }}
.col-r   {{ float: right; width: 48%; }}

/* ── hardware cards ── */
.hw-wrap {{ overflow: hidden; margin-bottom: 4mm; }}
.hw-card {{
  float: left; width: 30.5%; margin-right: 4%;
  border: 1px solid #dde4f0; border-radius: 6px;
  overflow: hidden; page-break-inside: avoid;
  margin-bottom: 3mm;
}}
.hw-card:nth-child(3n) {{ margin-right: 0; }}
.hw-head {{
  background: linear-gradient(90deg,#0d1b2a,#1b3a6b);
  color: #fff; padding: 2mm 3mm; font-size: 8pt; font-weight: 700;
}}
.hw-body {{
  padding: 2.5mm 3mm; font-size: 7.5pt; line-height: 1.75; background: #fafbff;
}}
.hw-role {{
  display: inline-block; background: #29b6f6; color: #fff;
  padding: .3mm 2mm; border-radius: 10px; font-size: 6.5pt; font-weight: 700;
  margin-bottom: 1.5mm;
}}

/* ── summary cards ── */
.card-wrap {{ overflow: hidden; margin-bottom: 4mm; }}
.card {{
  float: left; width: 46%; margin-right: 4%;
  border: 1px solid #dde4f0; border-radius: 6px;
  padding: 3mm 4mm; background: #fafbff;
  page-break-inside: avoid; margin-bottom: 3mm;
}}
.card:nth-child(2n) {{ margin-right: 0; }}
.card-title {{
  font-size: 8.5pt; font-weight: 700; color: #0d1b2a;
  margin-bottom: 1.5mm;
}}
.card-dot {{
  display: inline-block; width: 3mm; height: 3mm;
  border-radius: 50%; background: #29b6f6;
  margin-right: 2mm; vertical-align: middle;
}}
.card p {{ font-size: 8pt; color: #555; margin: 0; }}

/* ── toc ── */
.toc-row  {{ overflow: hidden; margin-bottom: 2mm; font-size: 9pt; }}
.toc-num  {{ float: left; width: 8mm; font-weight: 700; color: #1b3a6b; }}
.toc-text {{ float: left; }}
.toc-pg   {{ float: right; color: #888; font-size: 8.5pt; }}

/* ── steps ── */
ol.steps  {{ list-style: none; counter-reset: step; margin: 2mm 0 4mm 0; }}
ol.steps li {{
  counter-increment: step;
  position: relative; padding-left: 9mm;
  margin-bottom: 2.5mm; font-size: 8.5pt;
}}
ol.steps li::before {{
  content: counter(step);
  position: absolute; left: 0; top: .3mm;
  width: 6mm; height: 6mm;
  background: #1b3a6b; color: #fff;
  border-radius: 50%; font-size: 7pt; font-weight: 700;
  text-align: center; line-height: 6mm;
}}

/* ── separator ── */
.sep {{ height: 1px; background: linear-gradient(90deg,#1b3a6b,transparent);
        margin: 5mm 0; }}

/* ── diagrams ── */
.diag {{ text-align: center; margin: 4mm 0; page-break-inside: avoid; }}
.diag img {{ max-width: 100%; }}
.diag-cap {{
  font-size: 7.5pt; color: #888; margin-top: 2mm; font-style: italic;
}}

/* ── clear float helper ── */
.cf {{ clear: both; }}
</style>
</head>
<body>

<!-- ════════ COVER ════════ -->
<div class="cover">
  <div class="cover-bg1"></div>
  <div class="cover-bg2"></div>
  <div class="cover-stripe"></div>
  <div class="cover-body">
    <div class="cover-tag">Personal Homelab Infrastructure</div>
    <div class="cover-title">merox.dev<br>Infrastructure<br>Overview</div>
    <div class="cover-subtitle">Kubernetes · GitOps · Self-Hosted Cloud</div>
    <div class="cover-divider"></div>
    <div class="cover-name">Robert Melcher</div>
    <div class="cover-role">HPC System Administrator @ Forvia</div>
    <div class="cover-date">June 2026 &nbsp;·&nbsp; v3.0</div>
  </div>
  <div class="cover-stats">
    <div class="stat"><span class="stat-n">3</span><span class="stat-l">K8s Nodes</span></div>
    <div class="stat"><span class="stat-n">30+</span><span class="stat-l">Services</span></div>
    <div class="stat"><span class="stat-n">100%</span><span class="stat-l">GitOps</span></div>
    <div class="stat"><span class="stat-n">~€0</span><span class="stat-l">Cloud Cost</span></div>
    <div class="stat"><span class="stat-n">&lt;50'</span><span class="stat-l">Full Rebuild</span></div>
  </div>
</div>

<!-- ════════ PAGE 2 — TOC + SUMMARY ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">Table of Contents</h1></div>

  <div style="margin-bottom:7mm;">
    <div class="toc-row"><span class="toc-num">1.</span><span class="toc-text">Executive Summary</span><span class="toc-pg">3</span></div>
    <div class="toc-row"><span class="toc-num">2.</span><span class="toc-text">High-Level Architecture &amp; Network Topology</span><span class="toc-pg">3</span></div>
    <div class="toc-row"><span class="toc-num">3.</span><span class="toc-text">Hardware Inventory</span><span class="toc-pg">4</span></div>
    <div class="toc-row"><span class="toc-num">4.</span><span class="toc-text">Oracle Cloud VPS — Off-site Services</span><span class="toc-pg">5</span></div>
    <div class="toc-row"><span class="toc-num">5.</span><span class="toc-text">Kubernetes Cluster — On-premise</span><span class="toc-pg">6</span></div>
    <div class="toc-row"><span class="toc-num">6.</span><span class="toc-text">Networking &amp; Access Strategy</span><span class="toc-pg">7</span></div>
    <div class="toc-row"><span class="toc-num">7.</span><span class="toc-text">Storage &amp; Backup Architecture</span><span class="toc-pg">8</span></div>
    <div class="toc-row"><span class="toc-num">8.</span><span class="toc-text">GitOps &amp; Automation Pipeline</span><span class="toc-pg">9</span></div>
    <div class="toc-row"><span class="toc-num">9.</span><span class="toc-text">AI Agents (OpenClaw)</span><span class="toc-pg">10</span></div>
    <div class="toc-row"><span class="toc-num">10.</span><span class="toc-text">Security Model</span><span class="toc-pg">10</span></div>
    <div class="toc-row"><span class="toc-num">11.</span><span class="toc-text">Disaster Recovery</span><span class="toc-pg">11</span></div>
    <div class="toc-row"><span class="toc-num">12.</span><span class="toc-text">External Dependencies &amp; Costs</span><span class="toc-pg">12</span></div>
    <div class="toc-row"><span class="toc-num">13.</span><span class="toc-text">Day-to-Day Operations Quick Reference</span><span class="toc-pg">13</span></div>
  </div>

  <div class="sep"></div>

  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">1. Executive Summary</h1></div>

  <p>This document covers the complete <strong>merox.dev homelab infrastructure</strong> — a production-grade self-hosted environment running on commodity hardware and free-tier cloud. Design philosophy: <em>declarative, reproducible, zero-cost cloud.</em></p>

  <div class="card-wrap">
    <div class="card">
      <div class="card-title"><span class="card-dot"></span>Kubernetes Cluster</div>
      <p>3-node Talos Linux HA cluster (all control-plane + worker) on Proxmox VMs. Managed 100% via FluxCD GitOps — a single <code>git push</code> deploys or updates any workload.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#e94560;"></span>Oracle Cloud VPS</div>
      <p>Always-free ARM VPS (4 vCPU / 24GB) hosting off-site services: reverse proxy, SSO, DNS, S3 backup storage, monitoring, and AI agent runtime.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#43a047;"></span>Zero Open Ports</div>
      <p>All external traffic via <strong>Cloudflare Tunnel</strong>. Management via <strong>Tailscale</strong> mesh VPN. No public IP, no open firewall ports required anywhere.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#ff9800;"></span>AI Automation</div>
      <p><strong>OpenClaw</strong> runs Claude-powered agents — manage infrastructure, publish blog posts, get daily briefings, all via Telegram.</p>
    </div>
  </div>
  <div class="cf"></div>

  <div class="callout">
    <strong>Key facts</strong>
    Repo: <code>meroxdotdev/infrastructure</code> &nbsp;·&nbsp; Secrets: SOPS/AGE encrypted &nbsp;·&nbsp; Rebuild from scratch: ~50 min &nbsp;·&nbsp; Monthly cloud cost: ~€0 (Oracle free tier) &nbsp;·&nbsp; Fallback VPS on-demand: ~€5.39/mo (Hetzner)
  </div>
</div>

<!-- ════════ PAGE 3 — ARCHITECTURE TOPOLOGY ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">2. High-Level Architecture &amp; Network Topology</h1></div>
  <div class="diag">
    <img src="data:image/png;base64,{D_ARCH}" alt="Architecture diagram"/>
    <div class="diag-cap">Figure 1 — Complete infrastructure topology: VPS ↔ K8s cluster ↔ home network, with Cloudflare Tunnel and Tailscale overlay</div>
  </div>
</div>

<!-- ════════ PAGE 4 — HARDWARE ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">3. Hardware Inventory</h1></div>

  <div class="hw-wrap">
    <div class="hw-card">
      <div class="hw-head">Dell OptiPlex 3050 #1</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br>
        CPU: Intel i5-6500T (4C/4T)<br>RAM: 16 GB DDR4<br>
        Storage: 128 GB NVMe<br>IP: <code>10.57.57.80</code>
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">Dell OptiPlex 3050 #2</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br>
        CPU: Intel i5-6500T (4C/4T)<br>RAM: 16 GB DDR4<br>
        Storage: 128 GB NVMe<br>IP: <code>10.57.57.82</code>
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">Beelink GTi 13 Pro</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br>
        CPU: Intel i9-13900H (14C/20T)<br>RAM: 64 GB DDR5<br>
        Storage: 2×2 TB NVMe<br>IP: <code>10.57.57.84</code> · iGPU i915
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">Dell PowerEdge R720</div>
      <div class="hw-body">
        <span class="hw-role">Proxmox Backup Server</span><br>
        CPU: 2× Xeon E5-2697v2 (24C/48T)<br>RAM: 192 GB DDR3<br>
        Role: PBS + DR VMs
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">Synology DS223+</div>
      <div class="hw-body">
        <span class="hw-role">NAS · NFS + Backup</span><br>
        Storage: 2×2 TB HDD RAID1<br>Protocol: NFS<br>
        IP: <code>10.57.57.201</code><br>DB backups + media
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">XCY X44</div>
      <div class="hw-body">
        <span class="hw-role">Firewall / Router</span><br>
        CPU: Intel N100<br>RAM: 8 GB<br>
        OS: pfSense<br>Firewall · DHCP · Routing
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-head">Oracle Cloud ARM VPS</div>
      <div class="hw-body">
        <span class="hw-role">Off-site Cloud · Free tier</span><br>
        CPU: 4× vCPU ARM Ampere A1<br>RAM: 24 GB<br>
        Storage: 200 GB block<br>Cost: €0/mo
      </div>
    </div>
  </div>
  <div class="cf"></div>

  <div class="sep"></div>

  <h2>Network Addressing</h2>
  <table>
    <thead><tr><th>Device / Service</th><th>IP Address</th><th>Notes</th></tr></thead>
    <tbody>
      <tr><td>K8s API VIP (Talos)</td><td><code>10.57.57.88</code></td><td>HA control-plane endpoint</td></tr>
      <tr><td>K8s Node 1 (OptiPlex #1)</td><td><code>10.57.57.80</code></td><td>Proxmox VM</td></tr>
      <tr><td>K8s Node 2 (OptiPlex #2)</td><td><code>10.57.57.82</code></td><td>Proxmox VM</td></tr>
      <tr><td>K8s Node 3 (Beelink)</td><td><code>10.57.57.84</code></td><td>Proxmox VM · i915 iGPU</td></tr>
      <tr><td>Synology NAS</td><td><code>10.57.57.201</code></td><td>NFS server</td></tr>
      <tr><td>qBittorrent pod</td><td><code>10.57.57.102</code></td><td>Fixed IP via Cilium</td></tr>
      <tr><td>Portainer agent pod</td><td><code>10.57.57.103</code></td><td>Fixed IP via Cilium</td></tr>
      <tr><td>Oracle VPS (Tailscale)</td><td><code>100.72.22.38</code></td><td>Management access only</td></tr>
    </tbody>
  </table>
</div>

<!-- ════════ PAGE 5 — VPS SERVICES ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">4. Oracle Cloud VPS — Off-site Services</h1></div>

  <p>All services run as Docker Compose stacks under <code>/srv/docker/oracle-cloud/</code>. Traefik handles TLS. Authentik provides SSO.</p>

  <table>
    <thead><tr><th>Service</th><th>URL / Access</th><th>Purpose</th><th>Stack</th></tr></thead>
    <tbody>
      <tr><td><strong>Traefik</strong></td><td class="url">traefik.cloud.merox.dev</td><td>Reverse proxy · ACME TLS (Let's Encrypt) · routes all VPS traffic</td><td><span class="b b-blue">traefik/</span></td></tr>
      <tr><td><strong>Authentik</strong></td><td class="url">sso.merox.dev</td><td>SSO identity provider — Google-only, no new signups</td><td><span class="b b-purple">authentik/</span></td></tr>
      <tr><td><strong>Pi-hole + Unbound</strong></td><td class="url">pihole.cloud.merox.dev</td><td>DNS ad-blocking + recursive DoH resolver</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Portainer EE</strong></td><td class="url">100.72.22.38:9000 (Tailscale)</td><td>Container management UI</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Homepage</strong></td><td class="url">inside.merox.dev (Tailscale)</td><td>Internal dashboard — K8s + Proxmox + router</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Joplin Server</strong></td><td class="url">joplin.cloud.merox.dev</td><td>Self-hosted notes sync (PostgreSQL backend)</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Uptime Kuma</strong></td><td class="url">status.merox.dev</td><td>Service uptime monitoring + alerting</td><td><span class="b b-green">uptime-kuma/</span></td></tr>
      <tr><td><strong>Guacamole</strong></td><td class="url">rmt.merox.dev</td><td>Browser RDP/VNC/SSH gateway · Authentik SSO</td><td><span class="b b-teal">guacamole/</span></td></tr>
      <tr><td><strong>Garage S3</strong></td><td class="url">garage.cloud.merox.dev</td><td>S3-compatible object store — Longhorn backup target</td><td><span class="b b-orange">garage/</span></td></tr>
      <tr><td><strong>Netdata</strong></td><td class="url">netdata.cloud.merox.dev</td><td>Real-time metrics — parent + 3 child K8s nodes</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Beszel</strong></td><td class="url">beszel.cloud.merox.dev</td><td>Lightweight host monitoring dashboard</td><td><span class="b b-green">beszel/</span></td></tr>
      <tr><td><strong>Dozzle</strong></td><td class="url">dozzle.cloud.merox.dev</td><td>Real-time Docker log aggregation UI</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>Glances</strong></td><td class="url">glances.cloud.merox.dev</td><td>System resource monitoring</td><td><span class="b b-blue">compose.yml</span></td></tr>
      <tr><td><strong>OpenClaw Dashboard</strong></td><td class="url">agents.cloud.merox.dev</td><td>AI agent control panel (updated nightly)</td><td><span class="b b-purple">agents-dashboard/</span></td></tr>
      <tr><td><strong>Code Server</strong></td><td class="url">code.cloud.merox.dev</td><td>Browser-based VS Code for remote editing</td><td><span class="b b-blue">compose.yml</span></td></tr>
    </tbody>
  </table>

  <h2>VPS Management Commands</h2>
  <pre>cd /srv/kubernetes/infrastructure/vps

make health-check       # verify all services running
make setup              # full idempotent redeploy (Ansible)
make update             # OS package updates only
make check              # dry-run (--check --diff)
make restore            # interactive restore wizard (Joplin / Authentik)
make cleanup            # remove unused Docker images/volumes
make dr-full            # provision fallback VPS on Hetzner (~15 min)</pre>
</div>

<!-- ════════ PAGE 6 — KUBERNETES ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">5. Kubernetes Cluster — On-premise</h1></div>

  <p>3-node <strong>Talos Linux</strong> HA cluster — all nodes run control-plane + workloads (no dedicated workers). Managed via <strong>FluxCD v2</strong> GitOps from <code>meroxdotdev/infrastructure</code>.</p>

  <div class="two-col">
    <div class="col-l">
      <h2>Infrastructure Services</h2>
      <table>
        <thead><tr><th>Service</th><th>Namespace</th><th>Role</th></tr></thead>
        <tbody>
          <tr><td><strong>Cilium</strong></td><td>kube-system</td><td>CNI · L2 LoadBalancer · Gateway API · NetworkPolicy</td></tr>
          <tr><td><strong>Longhorn</strong></td><td>longhorn-system</td><td>Distributed block storage · S3 backup</td></tr>
          <tr><td><strong>cert-manager</strong></td><td>cert-manager</td><td>Automated TLS (Let's Encrypt)</td></tr>
          <tr><td><strong>Cloudflare Tunnel</strong></td><td>network</td><td>External access — zero open ports</td></tr>
          <tr><td><strong>k8s-gateway</strong></td><td>network</td><td>Internal DNS for <code>*.merox.dev</code></td></tr>
          <tr><td><strong>external-dns</strong></td><td>network</td><td>Syncs K8s ingress → Cloudflare DNS</td></tr>
          <tr><td><strong>FluxCD v2</strong></td><td>flux-system</td><td>GitOps controller</td></tr>
          <tr><td><strong>intel-device-plugin</strong></td><td>kube-system</td><td>Exposes i915 iGPU for Jellyfin</td></tr>
        </tbody>
      </table>
    </div>
    <div class="col-r">
      <h2>Observability Stack</h2>
      <table>
        <thead><tr><th>Service</th><th>Namespace</th><th>Role</th></tr></thead>
        <tbody>
          <tr><td><strong>Prometheus</strong></td><td>observability</td><td>Metrics + alerting rules</td></tr>
          <tr><td><strong>Grafana</strong></td><td>observability</td><td>Dashboards</td></tr>
          <tr><td><strong>Loki</strong></td><td>observability</td><td>Log aggregation</td></tr>
          <tr><td><strong>Promtail</strong></td><td>observability</td><td>Log shipper (DaemonSet)</td></tr>
          <tr><td><strong>AlertManager</strong></td><td>observability</td><td>Alerts + healthchecks.io</td></tr>
          <tr><td><strong>Portainer agent</strong></td><td>default</td><td>Connects to Portainer EE (VPS)</td></tr>
        </tbody>
      </table>
    </div>
  </div>
  <div class="cf"></div>

  <h2>Application Workloads</h2>
  <table>
    <thead><tr><th>Service</th><th>Purpose</th><th>Notes</th></tr></thead>
    <tbody>
      <tr><td><strong>Jellyfin</strong></td><td>Media server (movies, TV, music)</td><td>Intel i915 HW transcoding · NodePort 30096 (Samsung TV)</td></tr>
      <tr><td><strong>Jellyseerr</strong></td><td>Media request management UI</td><td>Users request → Radarr/Sonarr picks up</td></tr>
      <tr><td><strong>Radarr / Sonarr</strong></td><td>Movie &amp; TV automation</td><td>Monitors indexers, downloads, renames, moves</td></tr>
      <tr><td><strong>Prowlarr</strong></td><td>Unified torrent/NZB indexer</td><td>Single config, syncs to Radarr + Sonarr</td></tr>
      <tr><td><strong>qBittorrent</strong></td><td>Torrent download client</td><td>Fixed IP: <code>10.57.57.102</code> (Cilium)</td></tr>
      <tr><td><strong>n8n</strong></td><td>No-code workflow automation</td><td>GitHub webhooks, notifications</td></tr>
      <tr><td><strong>Authentik outpost</strong></td><td>SSO proxy for K8s apps</td><td>Connects to Authentik instance on VPS</td></tr>
    </tbody>
  </table>

  <pre>kubectl get nodes
kubectl get pods -A | grep -v Running      # find problem pods
kubectl get helmreleases -A                # all Helm releases + status
task reconcile                             # force Flux sync

task talos:apply-node   IP=10.57.57.80     # apply Talos config
task talos:upgrade-node IP=10.57.57.80     # upgrade Talos version
task talos:upgrade-k8s                     # upgrade Kubernetes</pre>
</div>

<!-- ════════ PAGE 7 — NETWORKING ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">6. Networking &amp; Access Strategy</h1></div>

  <div class="two-col">
    <div class="col-l">
      <div class="diag">
        <img src="data:image/png;base64,{D_NETWORK}" alt="Network diagram"/>
        <div class="diag-cap">Figure 2 — Public vs management access paths</div>
      </div>
    </div>
    <div class="col-r">
      <h2>Cloudflare Tunnel (Public)</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.85;">
        <li>Zero open firewall ports — anywhere</li>
        <li>All <code>*.merox.dev</code> public routes via tunnel</li>
        <li>TLS terminated at Cloudflare edge (free)</li>
        <li>DDoS protection + WAF included</li>
        <li>K8s: tunnel agent pod in <code>network</code> ns</li>
        <li>VPS: tunnel via Traefik container</li>
      </ul>

      <h2>Tailscale (Management)</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.85;">
        <li>VPS + K8s nodes + Proxmox in same mesh</li>
        <li>MagicDNS for hostname resolution</li>
        <li>VPS acts as exit node</li>
        <li>Portainer EE &amp; Homepage: Tailscale-only</li>
        <li>Longhorn → Garage S3 over Tailscale</li>
      </ul>

      <h2>Internal DNS (k8s-gateway)</h2>
      <p style="font-size:8.5pt;">Resolves <code>*.merox.dev</code> internally to Cilium L2 LB IPs — split-horizon DNS so internal clients use same URLs but traffic stays on LAN.</p>
    </div>
  </div>
  <div class="cf"></div>
</div>

<!-- ════════ PAGE 8 — STORAGE & BACKUP ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">7. Storage &amp; Backup Architecture</h1></div>

  <div class="diag">
    <img src="data:image/png;base64,{D_STORAGE}" alt="Storage diagram"/>
    <div class="diag-cap">Figure 3 — Storage layers and backup data flows</div>
  </div>

  <div class="two-col">
    <div class="col-l">
      <h2>Storage Layers</h2>
      <table>
        <thead><tr><th>Layer</th><th>Technology</th><th>Used For</th></tr></thead>
        <tbody>
          <tr><td>Block (replicated)</td><td>Longhorn</td><td>App config, databases, state</td></tr>
          <tr><td>File (NFS)</td><td>Synology DS223+</td><td>Media files, large datasets</td></tr>
          <tr><td>Object (S3)</td><td>Garage (VPS)</td><td>Longhorn volume snapshots</td></tr>
        </tbody>
      </table>
    </div>
    <div class="col-r">
      <h2>Backup Schedule</h2>
      <table>
        <thead><tr><th>What</th><th>When</th><th>Destination</th></tr></thead>
        <tbody>
          <tr><td>Longhorn volumes</td><td>Daily 02:00</td><td>Garage S3 (VPS)</td></tr>
          <tr><td>Authentik PostgreSQL</td><td>Manual pre-change</td><td>/srv/backups/authentik/</td></tr>
          <tr><td>Joplin PostgreSQL</td><td>Automatic cron</td><td>/srv/backups/</td></tr>
        </tbody>
      </table>
    </div>
  </div>
  <div class="cf"></div>

  <div class="callout danger">
    <strong>Critical — back up age.key offline</strong>
    <code>/srv/kubernetes/infrastructure/age.key</code> is the SOPS master key. Lost = all K8s secrets (Cloudflare token, Authentik, Longhorn S3 creds) are unrecoverable. Keep an encrypted offline copy.
  </div>
</div>

<!-- ════════ PAGE 9 — GITOPS ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">8. GitOps &amp; Automation Pipeline</h1></div>

  <div class="diag">
    <img src="data:image/png;base64,{D_GITOPS}" alt="GitOps pipeline diagram"/>
    <div class="diag-cap">Figure 4 — FluxCD GitOps pipeline: git push → Flux reconciliation → K8s cluster state</div>
  </div>

  <div class="two-col">
    <div class="col-l">
      <h2>FluxCD Pipeline</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.85;">
        <li>Source Controller polls GitHub every 1 min</li>
        <li>Kustomize Controller applies <code>kubernetes/</code> manifests</li>
        <li>Helm Controller reconciles all HelmRelease resources</li>
        <li>SOPS/AGE decrypts secrets at apply time</li>
        <li>Drift detection — auto-reverts manual changes</li>
        <li>Force sync: <code>task reconcile</code></li>
      </ul>
    </div>
    <div class="col-r">
      <h2>Renovate Automation</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.85;">
        <li>Runs every weekend via GitHub Actions</li>
        <li>Opens PRs for Helm chart + image tag updates</li>
        <li>Also tracks: Talos + Kubernetes versions</li>
        <li>Config: <code>.renovaterc.json5</code></li>
        <li>Images tagged with <code># renovate:</code> comments</li>
      </ul>
    </div>
  </div>
  <div class="cf"></div>

  <h2>SOPS Secrets</h2>
  <pre>sops kubernetes/apps/&lt;namespace&gt;/&lt;app&gt;/app/secret.sops.yaml   # edit secret

# After rotating the AGE key
find . -name "*.sops.*" -exec sops updatekeys {{}} \;</pre>

  <h2>Flux Troubleshooting</h2>
  <pre>flux get sources git -A
flux get kustomizations -A
flux logs --level=error
flux reconcile kustomization cluster-apps --with-source

# HelmRelease stuck — suspend + resume
flux suspend helmrelease &lt;name&gt; -n &lt;namespace&gt;
flux resume  helmrelease &lt;name&gt; -n &lt;namespace&gt;</pre>
</div>

<!-- ════════ PAGE 10 — AI AGENTS + SECURITY ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">9. AI Agents — OpenClaw</h1></div>

  <p>OpenClaw runs Claude-powered agents on the VPS. Agents triggered via <strong>Telegram bot</strong> or cron. The <code>infra</code> agent can run <code>kubectl</code> and <code>docker</code> commands remotely in natural language.</p>

  <table>
    <thead><tr><th>Agent</th><th>Trigger</th><th>Purpose</th></tr></thead>
    <tbody>
      <tr><td><strong>news</strong></td><td><span class="b b-blue">Cron + Telegram</span></td><td>Daily briefing — HackerNews + RSS, summarised by Claude</td></tr>
      <tr><td><strong>blog</strong></td><td><span class="b b-purple">Telegram</span></td><td>Writes and publishes posts to merox.dev via GitHub Actions</td></tr>
      <tr><td><strong>infra</strong></td><td><span class="b b-purple">Telegram</span></td><td>Runs <code>kubectl</code> / <code>docker</code> — natural language infra management</td></tr>
      <tr><td><strong>costs</strong></td><td><span class="b b-purple">Telegram</span></td><td>Infrastructure cost tracking and reporting</td></tr>
      <tr><td><strong>design</strong></td><td><span class="b b-purple">Telegram</span></td><td>Visual content generation</td></tr>
      <tr><td><strong>orchestrator</strong></td><td><span class="b b-gray">Internal</span></td><td>Routes messages between agents + scheduled tasks</td></tr>
      <tr><td><strong>dashboard</strong></td><td><span class="b b-gray">Cron nightly</span></td><td>Updates agents.cloud.merox.dev</td></tr>
      <tr><td><strong>renovate</strong></td><td><span class="b b-gray">Internal</span></td><td>Git dependency sync + PR creation</td></tr>
    </tbody>
  </table>

  <div class="sep"></div>

  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">10. Security Model</h1></div>

  <div class="two-col">
    <div class="col-l">
      <h2>Secret Handling</h2>
      <table>
        <thead><tr><th>Type</th><th>Method</th></tr></thead>
        <tbody>
          <tr><td>K8s secrets</td><td>SOPS/AGE → <code>*.sops.yaml</code></td></tr>
          <tr><td>VPS Ansible secrets</td><td>Ansible Vault</td></tr>
          <tr><td>Docker env vars</td><td><code>.env</code> (gitignored)</td></tr>
          <tr><td>Agent API keys</td><td><code>.openclaw/.env</code> (gitignored)</td></tr>
          <tr><td>Talos bootstrap</td><td><code>talsecret.sops.yaml</code></td></tr>
        </tbody>
      </table>
    </div>
    <div class="col-r">
      <h2>Access Control</h2>
      <table>
        <thead><tr><th>Layer</th><th>Mechanism</th></tr></thead>
        <tbody>
          <tr><td>External HTTP</td><td>Cloudflare Tunnel (no open ports)</td></tr>
          <tr><td>Management</td><td>Tailscale mesh VPN</td></tr>
          <tr><td>SSO</td><td>Authentik (Google-only)</td></tr>
          <tr><td>K8s RBAC</td><td>Talos hardened defaults</td></tr>
          <tr><td>Network policy</td><td>Cilium NetworkPolicy</td></tr>
        </tbody>
      </table>
    </div>
  </div>
  <div class="cf"></div>
</div>

<!-- ════════ PAGE 11 — DISASTER RECOVERY ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">11. Disaster Recovery</h1></div>

  <div class="callout warn">
    <strong>Prerequisites — have ready before any DR scenario</strong>
    <code>age.key</code> (SOPS master) · Ansible Vault password · Tailscale auth key (check expiry!) · Cloudflare API token
  </div>

  <h2>DR Scenario Matrix</h2>
  <table>
    <thead><tr><th>Scenario</th><th>Action</th><th>RTO</th></tr></thead>
    <tbody>
      <tr><td><strong>K8s cluster lost</strong> (nodes dead)</td><td>DR.md — provision DR VMs, bootstrap Talos, restore Longhorn from S3</td><td>~35 min</td></tr>
      <tr><td><strong>VPS lost</strong> (Oracle reclaims free tier)</td><td><code>cd vps &amp;&amp; make dr-full</code> then <code>make restore</code></td><td>~15 min</td></tr>
      <tr><td><strong>Full rebuild from scratch</strong></td><td>DEPLOY.md — Phase 1 (VPS) → Phase 2 (K8s) → Phase 3 (Agent)</td><td>~50 min</td></tr>
      <tr><td><strong>Single node lost</strong></td><td>New Proxmox VM + <code>task talos:apply-node</code></td><td>~10 min</td></tr>
      <tr><td><strong>New hardware</strong> (different IPs)</td><td>Edit <code>talconfig.yaml</code>, <code>cluster-vars.yaml</code>, <code>cilium/networks.yaml</code></td><td>~20 min</td></tr>
      <tr><td><strong>HelmRelease stuck</strong></td><td><code>flux suspend/resume helmrelease</code></td><td>&lt;5 min</td></tr>
    </tbody>
  </table>

  <h2>Full Rebuild — Phase 1 → 3</h2>
  <ol class="steps">
    <li><strong>Phase 1 — VPS (~15 min)</strong><br><code>cd vps &amp;&amp; make dr-full</code> — provisions Hetzner VPS + deploys all Docker services via cloud-init. Then: <code>make restore</code> to restore Joplin + Authentik databases.</li>
    <li><strong>Phase 2 — Kubernetes (~20 min)</strong><br>Copy <code>age.key</code>. Edit <code>talos/talconfig.yaml</code> (node IPs, install disk) and <code>kubernetes/components/common/cluster-vars.yaml</code>.<br>Run: <code>task bootstrap:talos</code> → <code>task bootstrap:apps</code> → <code>task restore:longhorn</code></li>
    <li><strong>Phase 3 — AI Agents (~15 min)</strong><br>Create <code>openclaw</code> user. Run <code>claude login</code> (Anthropic OAuth). Run <code>openclaw onboard</code>. Fill <code>.openclaw/.env</code>. Enable systemd service.</li>
    <li><strong>Validation</strong><br><code>kubectl get nodes</code> → all Ready · <code>docker ps | wc -l</code> → ~16 containers · Send Telegram message → bot replies.</li>
  </ol>

  <pre># Useful during recovery
kubectl -n &lt;ns&gt; describe pod &lt;pod&gt;
kubectl -n &lt;ns&gt; logs &lt;pod&gt; --previous
talosctl -n &lt;node-ip&gt; health
talosctl -n &lt;node-ip&gt; dmesg
docker exec garage /garage status</pre>
</div>

<!-- ════════ PAGE 12 — COSTS ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">12. External Dependencies &amp; Costs</h1></div>

  <table>
    <thead><tr><th>Service</th><th>Purpose</th><th>Cost</th><th>Tier</th></tr></thead>
    <tbody>
      <tr><td><strong>Cloudflare</strong></td><td>DNS · CDN · Tunnel · WAF · DDoS · Pages (blog CI/CD)</td><td>€0/mo</td><td><span class="b b-green">Free</span></td></tr>
      <tr><td><strong>Tailscale</strong></td><td>Management VPN mesh (all nodes + VPS)</td><td>€0/mo</td><td><span class="b b-green">Free</span></td></tr>
      <tr><td><strong>Oracle Cloud</strong></td><td>Primary VPS — 4 vCPU ARM, 24GB RAM, 200GB</td><td>€0/mo</td><td><span class="b b-green">Always Free</span></td></tr>
      <tr><td><strong>Hetzner VPS</strong></td><td>Fallback VPS — on-demand only if Oracle free tier lost</td><td>€5.39/mo</td><td><span class="b b-orange">On-demand</span></td></tr>
      <tr><td><strong>Anthropic / Claude</strong></td><td>Claude Pro — AI model powering OpenClaw agents</td><td>~$20/mo</td><td><span class="b b-blue">Claude Pro</span></td></tr>
      <tr><td><strong>GitHub</strong></td><td>Repos + GitHub Actions (blog CI, Renovate)</td><td>€0/mo</td><td><span class="b b-green">Free</span></td></tr>
      <tr><td><strong>Let's Encrypt</strong></td><td>HTTPS certificates (auto-renew via cert-manager)</td><td>€0/mo</td><td><span class="b b-green">Free</span></td></tr>
      <tr><td><strong>Proxmox</strong></td><td>Hypervisor for K8s VMs (own hardware)</td><td>€0/mo</td><td><span class="b b-teal">Own HW</span></td></tr>
      <tr><td><strong>Synology DS223+</strong></td><td>NAS — NFS + DB backups (own hardware)</td><td>€0/mo</td><td><span class="b b-teal">Own HW</span></td></tr>
    </tbody>
  </table>

  <div class="diag">
    <img src="data:image/png;base64,{C_COSTS}" alt="Cost breakdown chart"/>
    <div class="diag-cap">Figure 5 — Monthly cost breakdown (normal: ~$20 · with Hetzner fallback: ~€25)</div>
  </div>

  <h2>Repository Map</h2>
  <table>
    <thead><tr><th>What</th><th>GitHub Repo</th><th>Local Path</th></tr></thead>
    <tbody>
      <tr><td>K8s Flux manifests + Talos config</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/</td></tr>
      <tr><td>Ansible + Terraform VPS DR</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/vps/</td></tr>
      <tr><td>Docker Compose VPS services</td><td>meroxdotdev/cloudlab-merox</td><td>/srv/docker/oracle-cloud/</td></tr>
      <tr><td>OpenClaw agent config + skill</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/agent/</td></tr>
      <tr><td>Blog (Astro)</td><td>meroxdotdev/merox (private)</td><td>/srv/merox/</td></tr>
    </tbody>
  </table>
</div>

<!-- ════════ PAGE 13 — OPS REFERENCE ════════ -->
<div class="page">
  <div class="sh"><span class="sh-dot"></span><h1 class="sh-title">13. Day-to-Day Operations Quick Reference</h1></div>

  <div class="two-col">
    <div class="col-l">
      <h2>Kubernetes Cluster</h2>
      <pre>kubectl get nodes
kubectl get pods -A | grep -v Running
kubectl get helmreleases -A
kubectl get kustomizations -A
cilium status

task reconcile   # force Flux sync

task talos:generate-config
task talos:apply-node   IP=10.57.57.80
task talos:upgrade-node IP=10.57.57.80
task talos:upgrade-k8s</pre>

      <h2>Flux Troubleshooting</h2>
      <pre>flux get sources git -A
flux logs --level=error
flux reconcile kustomization \
  cluster-apps --with-source
flux suspend helmrelease &lt;n&gt; -n &lt;ns&gt;
flux resume  helmrelease &lt;n&gt; -n &lt;ns&gt;</pre>

      <h2>Pod Debugging</h2>
      <pre>kubectl -n &lt;ns&gt; describe pod &lt;pod&gt;
kubectl -n &lt;ns&gt; logs &lt;pod&gt; -f
kubectl -n &lt;ns&gt; logs &lt;pod&gt; --previous
kubectl -n &lt;ns&gt; get events \
  --sort-by='.metadata.creationTimestamp'</pre>
    </div>

    <div class="col-r">
      <h2>VPS / Docker</h2>
      <pre>cd /srv/docker/oracle-cloud
docker ps
docker ps | grep -v Up
docker logs &lt;name&gt; -f
docker compose up -d

cd /srv/kubernetes/infrastructure/vps
make health-check
make setup
make update
make restore
make dr-full</pre>

      <h2>Node Maintenance</h2>
      <pre>kubectl drain &lt;node&gt; \
  --ignore-daemonsets \
  --delete-emptydir-data
# do the work
kubectl uncordon &lt;node&gt;
# wait 1-2h between disk swaps
# for Longhorn replica rebuild</pre>

      <h2>Longhorn + Garage S3</h2>
      <pre>kubectl -n longhorn-system get volumes
kubectl -n longhorn-system get nodes.longhorn.io
# Remove orphaned replicas
kubectl get orphan \
  -n longhorn-system -o name | \
  xargs kubectl delete \
  -n longhorn-system

docker exec garage /garage status
docker exec garage /garage bucket list</pre>

      <h2>SOPS Secrets</h2>
      <pre>sops kubernetes/apps/&lt;ns&gt;/&lt;app&gt;/\
  app/secret.sops.yaml

# Rotate AGE key
find . -name "*.sops.*" \
  -exec sops updatekeys {{}} \;</pre>
    </div>
  </div>
  <div class="cf"></div>

  <div class="callout">
    <strong>Full Documentation</strong>
    Architecture index: <code>README.md</code> &nbsp;·&nbsp; Full rebuild: <code>DEPLOY.md</code> &nbsp;·&nbsp; K8s DR: <code>DR.md</code> &nbsp;·&nbsp; Jellyfin post-restore: <code>docs/jellyfin-post-restore.md</code>
  </div>

  <div style="margin-top:7mm; padding:4mm 5mm; background:#0d1b2a; border-radius:6px; overflow:hidden;">
    <div style="float:left;">
      <div style="font-size:10.5pt; font-weight:700; color:#fff;">Robert Melcher</div>
      <div style="font-size:8.5pt; color:#90caf9;">HPC System Administrator @ Forvia</div>
    </div>
    <div style="float:right; text-align:right;">
      <div style="font-size:8.5pt; color:#80cbc4;">merox.dev</div>
      <div style="font-size:8pt; color:#78909c;">github.com/meroxdotdev</div>
    </div>
    <div class="cf"></div>
  </div>
</div>

</body>
</html>"""

# ── render pdf ───────────────────────────────────────────────────────────────

print("Rendering PDF...")
weasyprint.HTML(string=HTML).write_pdf(
    "/srv/kubernetes/infrastructure/docs/infra-overview-2026.pdf"
)
print("Done: docs/infra-overview-2026.pdf")

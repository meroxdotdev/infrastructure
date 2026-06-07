#!/usr/bin/env python3
"""Generate a professional infrastructure overview PDF."""

import subprocess, sys

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<style>
  @page {
    size: A4;
    margin: 0;
  }
  @page content {
    size: A4;
    margin: 20mm 18mm 22mm 18mm;
    @bottom-center {
      content: "Robert Melcher · HPC System Administrator @ Forvia · merox.dev";
      font-size: 7.5pt;
      color: #888;
      font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
    }
    @bottom-right {
      content: counter(page);
      font-size: 7.5pt;
      color: #aaa;
      font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
    }
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
    font-size: 9.5pt;
    color: #2d2d2d;
    line-height: 1.5;
  }

  /* ── COVER ── */
  .cover {
    page: cover;
    width: 210mm;
    height: 297mm;
    background: linear-gradient(160deg, #0d1b2a 0%, #1b3a6b 55%, #162447 100%);
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: flex-start;
    padding: 28mm 22mm;
    position: relative;
    overflow: hidden;
  }
  @page cover { margin: 0; }

  .cover-accent {
    position: absolute;
    top: 0; right: 0;
    width: 90mm;
    height: 90mm;
    background: radial-gradient(circle at top right, rgba(41,182,246,0.18), transparent 70%);
  }
  .cover-bottom-accent {
    position: absolute;
    bottom: 0; left: 0;
    width: 120mm;
    height: 60mm;
    background: radial-gradient(circle at bottom left, rgba(233,69,96,0.12), transparent 70%);
  }
  .cover-tag {
    font-size: 8pt;
    font-weight: 700;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: #29b6f6;
    margin-bottom: 10mm;
  }
  .cover-title {
    font-size: 32pt;
    font-weight: 800;
    color: #ffffff;
    line-height: 1.15;
    margin-bottom: 5mm;
  }
  .cover-subtitle {
    font-size: 13pt;
    font-weight: 300;
    color: #90caf9;
    margin-bottom: 14mm;
  }
  .cover-divider {
    width: 40mm;
    height: 3px;
    background: linear-gradient(90deg, #29b6f6, #e94560);
    margin-bottom: 10mm;
    border-radius: 2px;
  }
  .cover-author {
    font-size: 11pt;
    font-weight: 600;
    color: #eceff1;
    margin-bottom: 2mm;
  }
  .cover-role {
    font-size: 9.5pt;
    font-weight: 400;
    color: #80cbc4;
    margin-bottom: 8mm;
  }
  .cover-date {
    font-size: 8.5pt;
    color: #78909c;
    margin-top: 4mm;
  }

  .cover-stats {
    position: absolute;
    bottom: 20mm;
    right: 22mm;
    display: flex;
    gap: 10mm;
  }
  .stat-box {
    text-align: center;
    background: rgba(255,255,255,0.07);
    border: 1px solid rgba(255,255,255,0.12);
    border-radius: 6px;
    padding: 5mm 7mm;
  }
  .stat-num {
    font-size: 18pt;
    font-weight: 800;
    color: #29b6f6;
    line-height: 1;
    display: block;
  }
  .stat-label {
    font-size: 7pt;
    color: #90caf9;
    text-transform: uppercase;
    letter-spacing: 1px;
    display: block;
    margin-top: 1mm;
  }

  /* ── CONTENT PAGES ── */
  .page {
    page: content;
    page-break-before: always;
  }

  /* ── SECTION HEADERS ── */
  .section-header {
    display: flex;
    align-items: center;
    gap: 4mm;
    margin-bottom: 5mm;
    padding-bottom: 3mm;
    border-bottom: 2px solid #1b3a6b;
  }
  .section-icon {
    width: 7mm;
    height: 7mm;
    background: linear-gradient(135deg, #1b3a6b, #29b6f6);
    border-radius: 3px;
    display: inline-block;
    flex-shrink: 0;
  }
  h1.section-title {
    font-size: 15pt;
    font-weight: 700;
    color: #0d1b2a;
    line-height: 1;
  }

  h2 {
    font-size: 11pt;
    font-weight: 700;
    color: #1b3a6b;
    margin: 5mm 0 3mm 0;
    padding-left: 3mm;
    border-left: 3px solid #29b6f6;
  }
  h3 {
    font-size: 9.5pt;
    font-weight: 700;
    color: #0d1b2a;
    margin: 4mm 0 2mm 0;
  }
  p { margin-bottom: 2.5mm; }

  /* ── TABLES ── */
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 8.5pt;
    margin-bottom: 4mm;
    page-break-inside: avoid;
  }
  thead tr {
    background: #1b3a6b;
    color: #fff;
  }
  thead th {
    padding: 2.5mm 3mm;
    text-align: left;
    font-weight: 600;
    font-size: 8pt;
    letter-spacing: 0.3px;
  }
  tbody tr:nth-child(even) { background: #f0f4ff; }
  tbody tr:nth-child(odd)  { background: #fafbff; }
  tbody td {
    padding: 2mm 3mm;
    border-bottom: 1px solid #dde4f0;
    vertical-align: top;
  }
  .td-url { color: #1565c0; font-size: 7.5pt; }
  .td-badge {
    display: inline-block;
    padding: 0.5mm 2mm;
    border-radius: 3px;
    font-size: 7pt;
    font-weight: 600;
  }
  .badge-blue   { background: #e3f2fd; color: #1565c0; }
  .badge-green  { background: #e8f5e9; color: #2e7d32; }
  .badge-orange { background: #fff3e0; color: #e65100; }
  .badge-red    { background: #fce4ec; color: #c62828; }
  .badge-purple { background: #f3e5f5; color: #6a1b9a; }
  .badge-teal   { background: #e0f2f1; color: #00695c; }

  /* ── CODE BLOCKS ── */
  pre {
    background: #1e2a3a;
    color: #cdd9e5;
    border-radius: 5px;
    padding: 3.5mm 4mm;
    font-family: 'Courier New', Courier, monospace;
    font-size: 7.5pt;
    line-height: 1.6;
    margin: 2mm 0 4mm 0;
    page-break-inside: avoid;
    white-space: pre-wrap;
  }
  code {
    background: #e8edf5;
    color: #1b3a6b;
    padding: 0.3mm 1.5mm;
    border-radius: 3px;
    font-family: 'Courier New', Courier, monospace;
    font-size: 8pt;
  }

  /* ── CALLOUT BOXES ── */
  .callout {
    border-left: 4px solid #29b6f6;
    background: #e3f2fd;
    padding: 3mm 4mm;
    margin: 3mm 0;
    border-radius: 0 5px 5px 0;
    font-size: 8.5pt;
    page-break-inside: avoid;
  }
  .callout.warning {
    border-left-color: #ff9800;
    background: #fff8e1;
  }
  .callout.danger {
    border-left-color: #e94560;
    background: #fce4ec;
  }
  .callout strong { display: block; margin-bottom: 1mm; font-size: 8pt; text-transform: uppercase; letter-spacing: 0.5px; color: #1565c0; }
  .callout.warning strong { color: #e65100; }
  .callout.danger strong  { color: #c62828; }

  /* ── GRID / CARD LAYOUT ── */
  .card-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 3mm;
    margin-bottom: 4mm;
  }
  .card {
    flex: 1 1 42%;
    border: 1px solid #dde4f0;
    border-radius: 6px;
    padding: 3mm 4mm;
    background: #fafbff;
    page-break-inside: avoid;
  }
  .card-title {
    font-size: 8.5pt;
    font-weight: 700;
    color: #0d1b2a;
    margin-bottom: 1.5mm;
    display: flex;
    align-items: center;
    gap: 2mm;
  }
  .card-dot {
    width: 3mm;
    height: 3mm;
    border-radius: 50%;
    background: #29b6f6;
    flex-shrink: 0;
  }
  .card p { font-size: 8pt; color: #555; margin: 0; }

  /* ── HARDWARE CARDS ── */
  .hw-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 3mm;
    margin-bottom: 5mm;
  }
  .hw-card {
    flex: 1 1 30%;
    border: 1px solid #dde4f0;
    border-radius: 6px;
    overflow: hidden;
    page-break-inside: avoid;
    background: #fff;
  }
  .hw-header {
    background: linear-gradient(90deg, #0d1b2a, #1b3a6b);
    color: #fff;
    padding: 2mm 3mm;
    font-size: 8pt;
    font-weight: 700;
  }
  .hw-body {
    padding: 2.5mm 3mm;
    font-size: 7.5pt;
    line-height: 1.7;
  }
  .hw-role {
    display: inline-block;
    background: #29b6f6;
    color: #fff;
    padding: 0.3mm 2mm;
    border-radius: 10px;
    font-size: 7pt;
    font-weight: 600;
    margin-bottom: 1.5mm;
  }

  /* ── TWO-COLUMN LAYOUT ── */
  .two-col {
    display: flex;
    gap: 5mm;
    margin-bottom: 4mm;
  }
  .col { flex: 1; }

  /* ── STEP LIST ── */
  .steps {
    counter-reset: step;
    list-style: none;
    margin: 2mm 0 4mm 0;
  }
  .steps li {
    counter-increment: step;
    display: flex;
    align-items: flex-start;
    gap: 3mm;
    margin-bottom: 2.5mm;
    font-size: 8.5pt;
  }
  .steps li::before {
    content: counter(step);
    display: inline-flex;
    width: 5.5mm;
    height: 5.5mm;
    background: #1b3a6b;
    color: #fff;
    border-radius: 50%;
    font-size: 7pt;
    font-weight: 700;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    margin-top: 0.5mm;
  }

  /* ── TOC ── */
  .toc-item {
    display: flex;
    align-items: baseline;
    margin-bottom: 2mm;
    font-size: 9pt;
  }
  .toc-num {
    font-weight: 700;
    color: #1b3a6b;
    width: 8mm;
    flex-shrink: 0;
  }
  .toc-title { flex: 1; }
  .toc-dots {
    flex: 1;
    border-bottom: 1px dotted #ccc;
    margin: 0 2mm 1mm 2mm;
  }
  .toc-page {
    width: 6mm;
    text-align: right;
    color: #888;
    font-size: 8.5pt;
  }

  /* ── STATUS INDICATORS ── */
  .status-row {
    display: flex;
    align-items: center;
    gap: 2mm;
    font-size: 8pt;
    margin-bottom: 1.5mm;
  }
  .status-dot {
    width: 2.5mm;
    height: 2.5mm;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .status-dot.green  { background: #43a047; }
  .status-dot.blue   { background: #29b6f6; }
  .status-dot.orange { background: #ff9800; }

  /* ── SEPARATOR ── */
  .sep {
    height: 1px;
    background: linear-gradient(90deg, #1b3a6b, transparent);
    margin: 5mm 0;
  }

  /* ── SVG DIAGRAMS ── */
  .diagram-wrap {
    text-align: center;
    margin: 4mm 0;
    page-break-inside: avoid;
  }
  .diagram-caption {
    font-size: 7.5pt;
    color: #888;
    text-align: center;
    margin-top: 2mm;
    font-style: italic;
  }
</style>
</head>
<body>

<!-- ══════════════════════════════════════════
     COVER PAGE
══════════════════════════════════════════ -->
<div class="cover">
  <div class="cover-accent"></div>
  <div class="cover-bottom-accent"></div>

  <div class="cover-tag">Personal Homelab Infrastructure</div>
  <div class="cover-title">merox.dev<br/>Infrastructure<br/>Overview</div>
  <div class="cover-subtitle">Kubernetes · GitOps · Self-Hosted Cloud</div>
  <div class="cover-divider"></div>
  <div class="cover-author">Robert Melcher</div>
  <div class="cover-role">HPC System Administrator @ Forvia</div>
  <div class="cover-date">June 2026 · v2.0</div>

  <div class="cover-stats">
    <div class="stat-box">
      <span class="stat-num">3</span>
      <span class="stat-label">K8s Nodes</span>
    </div>
    <div class="stat-box">
      <span class="stat-num">30+</span>
      <span class="stat-label">Services</span>
    </div>
    <div class="stat-box">
      <span class="stat-num">100%</span>
      <span class="stat-label">GitOps</span>
    </div>
    <div class="stat-box">
      <span class="stat-num">~€0</span>
      <span class="stat-label">Cloud Cost</span>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════════
     PAGE 2 — TABLE OF CONTENTS + SUMMARY
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">Table of Contents</h1>
  </div>

  <div style="margin-bottom:8mm;">
    <div class="toc-item"><span class="toc-num">1.</span><span class="toc-title">Executive Summary</span><span class="toc-dots"></span><span class="toc-page">3</span></div>
    <div class="toc-item"><span class="toc-num">2.</span><span class="toc-title">High-Level Architecture &amp; Network Topology</span><span class="toc-dots"></span><span class="toc-page">3</span></div>
    <div class="toc-item"><span class="toc-num">3.</span><span class="toc-title">Hardware Inventory</span><span class="toc-dots"></span><span class="toc-page">4</span></div>
    <div class="toc-item"><span class="toc-num">4.</span><span class="toc-title">Oracle Cloud VPS — Off-site Services</span><span class="toc-dots"></span><span class="toc-page">5</span></div>
    <div class="toc-item"><span class="toc-num">5.</span><span class="toc-title">Kubernetes Cluster — On-premise</span><span class="toc-dots"></span><span class="toc-page">6</span></div>
    <div class="toc-item"><span class="toc-num">6.</span><span class="toc-title">Networking &amp; Access Strategy</span><span class="toc-dots"></span><span class="toc-page">7</span></div>
    <div class="toc-item"><span class="toc-num">7.</span><span class="toc-title">Storage &amp; Backup Architecture</span><span class="toc-dots"></span><span class="toc-page">8</span></div>
    <div class="toc-item"><span class="toc-num">8.</span><span class="toc-title">GitOps &amp; Automation</span><span class="toc-dots"></span><span class="toc-page">9</span></div>
    <div class="toc-item"><span class="toc-num">9.</span><span class="toc-title">AI Agents (OpenClaw)</span><span class="toc-dots"></span><span class="toc-page">10</span></div>
    <div class="toc-item"><span class="toc-num">10.</span><span class="toc-title">Security Model</span><span class="toc-dots"></span><span class="toc-page">10</span></div>
    <div class="toc-item"><span class="toc-num">11.</span><span class="toc-title">Disaster Recovery</span><span class="toc-dots"></span><span class="toc-page">11</span></div>
    <div class="toc-item"><span class="toc-num">12.</span><span class="toc-title">External Dependencies &amp; Costs</span><span class="toc-dots"></span><span class="toc-page">12</span></div>
    <div class="toc-item"><span class="toc-num">13.</span><span class="toc-title">Day-to-Day Operations Quick Reference</span><span class="toc-dots"></span><span class="toc-page">13</span></div>
  </div>

  <div class="sep"></div>

  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">1. Executive Summary</h1>
  </div>

  <p>This document provides a complete reference for the <strong>merox.dev homelab infrastructure</strong> — a production-grade self-hosted environment running on commodity hardware and free-tier cloud services. The design philosophy is: <em>declarative, reproducible, and zero-cost cloud.</em></p>

  <div class="card-grid" style="margin-top:4mm;">
    <div class="card">
      <div class="card-title"><span class="card-dot"></span>Kubernetes Cluster</div>
      <p>3-node Talos Linux HA cluster (no workers — all control-plane) running on Proxmox VMs. Managed 100% via FluxCD GitOps. A single <code>git push</code> deploys or updates any workload.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#e94560;"></span>Oracle Cloud VPS</div>
      <p>Always-free ARM VPS (4 vCPU / 24GB) hosting off-site services: reverse proxy, SSO, DNS, S3 backup storage, monitoring, and AI agent runtime.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#43a047;"></span>Zero Open Ports</div>
      <p>All external traffic routes through <strong>Cloudflare Tunnel</strong> (no firewall holes). Internal management uses <strong>Tailscale</strong> mesh VPN. No public IP required.</p>
    </div>
    <div class="card">
      <div class="card-title"><span class="card-dot" style="background:#ff9800;"></span>AI Automation</div>
      <p><strong>OpenClaw</strong> AI agent framework runs Claude-powered agents — manage infrastructure, publish blog posts, and get daily briefings via Telegram.</p>
    </div>
  </div>

  <div class="callout">
    <strong>Key Facts</strong>
    Git repo: <code>meroxdotdev/infrastructure</code> · Secrets: SOPS/AGE encrypted · Rebuild time from scratch: ~50 min · Monthly cloud cost: ~€0 (Oracle free tier) · Fallback VPS on-demand: ~€5.39/mo (Hetzner)
  </div>
</div>

<!-- ══════════════════════════════════════════
     PAGE 3 — ARCHITECTURE TOPOLOGY
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">2. High-Level Architecture &amp; Network Topology</h1>
  </div>

  <div class="diagram-wrap">
    <svg width="160mm" height="115mm" viewBox="0 0 600 430" xmlns="http://www.w3.org/2000/svg" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
      <defs>
        <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="#29b6f6"/>
        </marker>
        <marker id="arrow-gray" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="#90a4ae"/>
        </marker>
        <marker id="arrow-green" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="#43a047"/>
        </marker>
        <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
          <feDropShadow dx="2" dy="3" stdDeviation="4" flood-opacity="0.18"/>
        </filter>
      </defs>

      <!-- Internet / Users -->
      <ellipse cx="300" cy="38" rx="90" ry="22" fill="#eceff1" stroke="#90a4ae" stroke-width="1.5"/>
      <text x="300" y="43" text-anchor="middle" font-size="13" font-weight="700" fill="#455a64">Internet / Users</text>

      <!-- Cloudflare -->
      <rect x="420" y="18" width="130" height="36" rx="7" fill="#fff3e0" stroke="#ff9800" stroke-width="1.5" filter="url(#shadow)"/>
      <text x="485" y="34" text-anchor="middle" font-size="11" font-weight="700" fill="#e65100">Cloudflare</text>
      <text x="485" y="47" text-anchor="middle" font-size="9" fill="#bf360c">Tunnel · DNS · Pages</text>

      <!-- Tailscale mesh -->
      <rect x="50" y="18" width="120" height="36" rx="7" fill="#e8f5e9" stroke="#43a047" stroke-width="1.5" filter="url(#shadow)"/>
      <text x="110" y="34" text-anchor="middle" font-size="11" font-weight="700" fill="#2e7d32">Tailscale</text>
      <text x="110" y="47" text-anchor="middle" font-size="9" fill="#388e3c">Mesh VPN</text>

      <!-- VPS Box -->
      <rect x="30" y="100" width="250" height="145" rx="10" fill="#e3f2fd" stroke="#1565c0" stroke-width="2" filter="url(#shadow)"/>
      <rect x="30" y="100" width="250" height="28" rx="10" fill="#1565c0"/>
      <rect x="30" y="115" width="250" height="13" fill="#1565c0"/>
      <text x="155" y="119" text-anchor="middle" font-size="12" font-weight="700" fill="#fff">Oracle Cloud VPS  |  4 vCPU ARM · 24GB</text>
      <text x="60" y="148" font-size="9.5" fill="#0d47a1">▸ Traefik  (reverse proxy + TLS)</text>
      <text x="60" y="163" font-size="9.5" fill="#0d47a1">▸ Authentik  (SSO / identity)</text>
      <text x="60" y="178" font-size="9.5" fill="#0d47a1">▸ Pi-hole + Unbound  (DNS + DoH)</text>
      <text x="60" y="193" font-size="9.5" fill="#0d47a1">▸ Garage S3  (Longhorn backup target)</text>
      <text x="60" y="208" font-size="9.5" fill="#0d47a1">▸ Monitoring: Netdata · Beszel · Dozzle</text>
      <text x="60" y="223" font-size="9.5" fill="#0d47a1">▸ OpenClaw AI agents · Code Server</text>

      <!-- K8s Box -->
      <rect x="320" y="100" width="255" height="185" rx="10" fill="#f3e5f5" stroke="#7b1fa2" stroke-width="2" filter="url(#shadow)"/>
      <rect x="320" y="100" width="255" height="28" rx="10" fill="#7b1fa2"/>
      <rect x="320" y="115" width="255" height="13" fill="#7b1fa2"/>
      <text x="448" y="119" text-anchor="middle" font-size="12" font-weight="700" fill="#fff">Kubernetes Cluster (Talos Linux)</text>
      <text x="348" y="148" font-size="9.5" fill="#4a148c">▸ 3× control-plane nodes (Proxmox VMs)</text>
      <text x="348" y="163" font-size="9.5" fill="#4a148c">▸ Cilium  CNI · L2 LB · Gateway API</text>
      <text x="348" y="178" font-size="9.5" fill="#4a148c">▸ Longhorn  distributed storage</text>
      <text x="348" y="193" font-size="9.5" fill="#4a148c">▸ Media: Jellyfin · Radarr · Sonarr</text>
      <text x="348" y="208" font-size="9.5" fill="#4a148c">▸ Monitoring: Prometheus · Grafana · Loki</text>
      <text x="348" y="223" font-size="9.5" fill="#4a148c">▸ n8n automation · Authentik outpost</text>
      <text x="348" y="238" font-size="9.5" fill="#4a148c">▸ FluxCD GitOps (GitHub → cluster)</text>
      <text x="348" y="253" font-size="9.5" fill="#4a148c">▸ cert-manager · k8s-gateway · CF Tunnel</text>
      <text x="348" y="268" font-size="9.5" fill="#4a148c">▸ Portainer agent (connects to VPS)</text>

      <!-- NAS Box -->
      <rect x="160" y="315" width="145" height="58" rx="8" fill="#e8f5e9" stroke="#2e7d32" stroke-width="1.5" filter="url(#shadow)"/>
      <text x="232" y="336" text-anchor="middle" font-size="11" font-weight="700" fill="#1b5e20">Synology DS223+</text>
      <text x="232" y="352" text-anchor="middle" font-size="9" fill="#2e7d32">NAS · NFS mount for K8s</text>
      <text x="232" y="364" text-anchor="middle" font-size="9" fill="#2e7d32">DB backups · 2×2TB RAID1</text>

      <!-- pfSense Box -->
      <rect x="350" y="315" width="130" height="58" rx="8" fill="#fff3e0" stroke="#f57c00" stroke-width="1.5" filter="url(#shadow)"/>
      <text x="415" y="336" text-anchor="middle" font-size="11" font-weight="700" fill="#e65100">pfSense</text>
      <text x="415" y="352" text-anchor="middle" font-size="9" fill="#bf360c">XCY X44 · N100</text>
      <text x="415" y="364" text-anchor="middle" font-size="9" fill="#bf360c">Firewall · DHCP · Routing</text>

      <!-- GitHub Box -->
      <rect x="200" y="400" width="195" height="26" rx="7" fill="#fff" stroke="#333" stroke-width="1.5"/>
      <text x="297" y="417" text-anchor="middle" font-size="10" font-weight="700" fill="#24292e">GitHub  (meroxdotdev/infrastructure)</text>

      <!-- Arrows: Internet -> Cloudflare -->
      <line x1="390" y1="38" x2="420" y2="38" stroke="#ff9800" stroke-width="2" marker-end="url(#arrow)"/>
      <!-- Cloudflare -> VPS Traefik -->
      <path d="M485,54 Q485,80 280,100" fill="none" stroke="#ff9800" stroke-width="1.8" stroke-dasharray="5,3" marker-end="url(#arrow)"/>
      <!-- Cloudflare -> K8s CF Tunnel -->
      <path d="M485,54 L485,100" fill="none" stroke="#ff9800" stroke-width="1.8" stroke-dasharray="5,3" marker-end="url(#arrow)"/>
      <!-- Tailscale <-> VPS -->
      <line x1="155" y1="38" x2="155" y2="100" stroke="#43a047" stroke-width="1.8" marker-end="url(#arrow)"/>
      <!-- Tailscale <-> K8s -->
      <path d="M170,38 Q250,65 320,140" fill="none" stroke="#43a047" stroke-width="1.8" stroke-dasharray="4,3" marker-end="url(#arrow)"/>
      <!-- VPS <-> K8s (Tailscale mesh) -->
      <line x1="280" y1="172" x2="320" y2="172" stroke="#29b6f6" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arrow)"/>
      <text x="300" y="167" text-anchor="middle" font-size="8" fill="#0277bd">S3 backup</text>
      <!-- K8s -> NAS (NFS) -->
      <path d="M400,285 Q330,300 280,315" fill="none" stroke="#43a047" stroke-width="1.5" marker-end="url(#arrow)"/>
      <text x="330" y="297" text-anchor="middle" font-size="8" fill="#2e7d32">NFS</text>
      <!-- GitHub -> Flux -->
      <path d="M297,400 Q350,370 400,285" fill="none" stroke="#90a4ae" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arrow-gray)"/>
      <text x="370" y="368" font-size="8" fill="#607d8b">GitOps</text>
    </svg>
    <div class="diagram-caption">Figure 1 — High-level infrastructure topology showing all major components and their interconnections</div>
  </div>
</div>

<!-- ══════════════════════════════════════════
     PAGE 4 — HARDWARE
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">3. Hardware Inventory</h1>
  </div>

  <div class="hw-grid">
    <div class="hw-card">
      <div class="hw-header">Dell OptiPlex 3050 #1</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br/>
        CPU: Intel i5-6500T (4C/4T)<br/>
        RAM: 16 GB DDR4<br/>
        Storage: 128 GB NVMe<br/>
        IP: 10.57.57.80
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">Dell OptiPlex 3050 #2</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br/>
        CPU: Intel i5-6500T (4C/4T)<br/>
        RAM: 16 GB DDR4<br/>
        Storage: 128 GB NVMe<br/>
        IP: 10.57.57.82
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">Beelink GTi 13 Pro</div>
      <div class="hw-body">
        <span class="hw-role">K8s Node · Proxmox VM</span><br/>
        CPU: Intel i9-13900H (14C/20T)<br/>
        RAM: 64 GB DDR5<br/>
        Storage: 2× 2 TB NVMe<br/>
        IP: 10.57.57.84 · iGPU: Intel Arc (i915)
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">Dell PowerEdge R720</div>
      <div class="hw-body">
        <span class="hw-role">Proxmox Backup Server</span><br/>
        CPU: 2× Xeon E5-2697v2 (24C/48T)<br/>
        RAM: 192 GB DDR3<br/>
        Storage: Large HDD pool<br/>
        Role: PBS + DR VMs
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">Synology DS223+</div>
      <div class="hw-body">
        <span class="hw-role">NAS · NFS + Backup</span><br/>
        Storage: 2× 2 TB HDD RAID1<br/>
        Protocol: NFS (K8s volumes)<br/>
        IP: 10.57.57.201<br/>
        Role: DB backups + media storage
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">XCY X44</div>
      <div class="hw-body">
        <span class="hw-role">Firewall / Router</span><br/>
        CPU: Intel N100<br/>
        RAM: 8 GB<br/>
        OS: pfSense<br/>
        Role: Firewall · DHCP · Routing
      </div>
    </div>
    <div class="hw-card">
      <div class="hw-header">Oracle Cloud ARM VPS</div>
      <div class="hw-body">
        <span class="hw-role">Off-site Cloud (Free tier)</span><br/>
        CPU: 4× vCPU ARM Ampere A1<br/>
        RAM: 24 GB<br/>
        Storage: 200 GB block storage<br/>
        Cost: €0/mo (always free)
      </div>
    </div>
  </div>

  <div class="sep"></div>

  <h2>Network Addressing</h2>
  <table>
    <thead><tr><th>Device/Service</th><th>IP / Address</th><th>Notes</th></tr></thead>
    <tbody>
      <tr><td>K8s VIP (Talos)</td><td><code>10.57.57.88</code></td><td>Kubernetes API endpoint (HA)</td></tr>
      <tr><td>K8s Node 1</td><td><code>10.57.57.80</code></td><td>OptiPlex 3050 #1</td></tr>
      <tr><td>K8s Node 2</td><td><code>10.57.57.82</code></td><td>OptiPlex 3050 #2</td></tr>
      <tr><td>K8s Node 3</td><td><code>10.57.57.84</code></td><td>Beelink GTi 13 Pro</td></tr>
      <tr><td>Synology NAS</td><td><code>10.57.57.201</code></td><td>NFS + DB backup target</td></tr>
      <tr><td>qBittorrent pod</td><td><code>10.57.57.102</code></td><td>Fixed IP (Cilium)</td></tr>
      <tr><td>Portainer agent pod</td><td><code>10.57.57.103</code></td><td>Fixed IP (Cilium)</td></tr>
      <tr><td>Oracle VPS (Tailscale)</td><td><code>100.72.22.38</code></td><td>Management access</td></tr>
    </tbody>
  </table>
</div>

<!-- ══════════════════════════════════════════
     PAGE 5 — VPS SERVICES
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">4. Oracle Cloud VPS — Off-site Services</h1>
  </div>

  <p>All services run as Docker Compose stacks under <code>/srv/docker/oracle-cloud/</code>. Traefik handles TLS termination and routing. Authentik provides SSO for protected services.</p>

  <table>
    <thead><tr><th>Service</th><th>URL / Access</th><th>Purpose</th><th>Stack</th></tr></thead>
    <tbody>
      <tr><td><strong>Traefik</strong></td><td class="td-url">traefik.cloud.merox.dev</td><td>Reverse proxy · ACME TLS (Let's Encrypt) · routes all VPS services</td><td><span class="td-badge badge-blue">traefik/</span></td></tr>
      <tr><td><strong>Authentik</strong></td><td class="td-url">sso.merox.dev</td><td>SSO identity provider — Google-only login, no new signups</td><td><span class="td-badge badge-purple">authentik/</span></td></tr>
      <tr><td><strong>Pi-hole + Unbound</strong></td><td class="td-url">pihole.cloud.merox.dev/admin</td><td>DNS ad-blocking + DNS-over-HTTPS recursive resolver</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Portainer EE</strong></td><td class="td-url">100.72.22.38:9000 (Tailscale)</td><td>Container management UI — manages all Docker services on VPS</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Homepage</strong></td><td class="td-url">inside.merox.dev (Tailscale)</td><td>Internal dashboard showing K8s + Proxmox + router status</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Joplin Server</strong></td><td class="td-url">joplin.cloud.merox.dev</td><td>Self-hosted notes sync with PostgreSQL backend</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Uptime Kuma</strong></td><td class="td-url">status.merox.dev</td><td>Service uptime monitoring + alerting</td><td><span class="td-badge badge-green">uptime-kuma/</span></td></tr>
      <tr><td><strong>Guacamole</strong></td><td class="td-url">rmt.merox.dev</td><td>Browser-based remote desktop gateway (RDP/VNC/SSH) · Authentik SSO</td><td><span class="td-badge badge-teal">guacamole/</span></td></tr>
      <tr><td><strong>Garage S3</strong></td><td class="td-url">garage.cloud.merox.dev</td><td>S3-compatible object storage — receives Longhorn volume backups from homelab</td><td><span class="td-badge badge-orange">garage/</span></td></tr>
      <tr><td><strong>Netdata</strong></td><td class="td-url">netdata.cloud.merox.dev</td><td>Real-time metrics — parent node + 3 K8s child nodes</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Beszel</strong></td><td class="td-url">beszel.cloud.merox.dev</td><td>Lightweight host monitoring dashboard</td><td><span class="td-badge badge-green">beszel/</span></td></tr>
      <tr><td><strong>Dozzle</strong></td><td class="td-url">dozzle.cloud.merox.dev</td><td>Real-time Docker log aggregation UI</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Glances</strong></td><td class="td-url">glances.cloud.merox.dev</td><td>System resource monitoring (CPU, RAM, disk, network)</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>OpenClaw Dashboard</strong></td><td class="td-url">agents.cloud.merox.dev</td><td>AI agent control panel — updated nightly</td><td><span class="td-badge badge-purple">agents-dashboard/</span></td></tr>
      <tr><td><strong>Code Server</strong></td><td class="td-url">code.cloud.merox.dev</td><td>Browser-based VS Code for remote editing</td><td><span class="td-badge badge-blue">docker-compose.yml</span></td></tr>
      <tr><td><strong>Filebrowser</strong></td><td class="td-url">files.cloud.merox.dev</td><td>Web-based file manager for VPS storage</td><td><span class="td-badge badge-teal">filebrowser/</span></td></tr>
    </tbody>
  </table>

  <h2>VPS Management Commands</h2>
  <pre>cd /srv/docker/oracle-cloud

make health-check       # verify all services running
make setup              # full idempotent redeploy via Ansible
make update             # OS package updates only
make check              # dry-run (--check --diff)
make restore            # interactive restore wizard (Joplin / Authentik)
make cleanup            # remove unused Docker images/volumes
make dr-full            # provision fallback VPS on Hetzner (~15 min)</pre>
</div>

<!-- ══════════════════════════════════════════
     PAGE 6 — KUBERNETES CLUSTER
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">5. Kubernetes Cluster — On-premise</h1>
  </div>

  <p>3-node <strong>Talos Linux</strong> cluster — all nodes run both control-plane and workloads (no dedicated workers). Managed via <strong>FluxCD v2</strong> GitOps. Charts sourced via OCI where possible (bjw-s-labs app-template 4.x).</p>

  <div class="two-col">
    <div class="col">
      <h2>Infrastructure Services</h2>
      <table>
        <thead><tr><th>Service</th><th>Namespace</th><th>Role</th></tr></thead>
        <tbody>
          <tr><td><strong>Cilium</strong></td><td>kube-system</td><td>CNI · Gateway API · L2 LoadBalancer · NetworkPolicy</td></tr>
          <tr><td><strong>Longhorn</strong></td><td>longhorn-system</td><td>Distributed block storage · S3 backup to Garage</td></tr>
          <tr><td><strong>cert-manager</strong></td><td>cert-manager</td><td>Automated TLS (Let's Encrypt ACME)</td></tr>
          <tr><td><strong>Cloudflare Tunnel</strong></td><td>network</td><td>External access — zero open ports required</td></tr>
          <tr><td><strong>k8s-gateway</strong></td><td>network</td><td>Internal DNS for <code>*.merox.dev</code></td></tr>
          <tr><td><strong>external-dns</strong></td><td>network</td><td>Syncs K8s ingress → Cloudflare DNS</td></tr>
          <tr><td><strong>FluxCD</strong></td><td>flux-system</td><td>GitOps controller (GitHub → cluster)</td></tr>
          <tr><td><strong>intel-device-plugin</strong></td><td>kube-system</td><td>Exposes i915 iGPU for Jellyfin transcoding</td></tr>
        </tbody>
      </table>
    </div>
    <div class="col">
      <h2>Observability Stack</h2>
      <table>
        <thead><tr><th>Service</th><th>Namespace</th><th>Role</th></tr></thead>
        <tbody>
          <tr><td><strong>Prometheus</strong></td><td>observability</td><td>Metrics collection + alerting rules</td></tr>
          <tr><td><strong>Grafana</strong></td><td>observability</td><td>Dashboards (K8s, Longhorn, apps)</td></tr>
          <tr><td><strong>Loki</strong></td><td>observability</td><td>Log aggregation backend</td></tr>
          <tr><td><strong>Promtail</strong></td><td>observability</td><td>Log shipper (DaemonSet)</td></tr>
          <tr><td><strong>AlertManager</strong></td><td>observability</td><td>Alerts + healthchecks.io heartbeat</td></tr>
          <tr><td><strong>Portainer Agent</strong></td><td>default</td><td>Connects to Portainer EE on VPS</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <h2>Application Workloads</h2>
  <table>
    <thead><tr><th>Service</th><th>Namespace</th><th>Purpose</th><th>Notes</th></tr></thead>
    <tbody>
      <tr><td><strong>Jellyfin</strong></td><td>default</td><td>Media server — movies, TV, music</td><td>Intel i915 iGPU hardware transcoding · NodePort 30096 (Samsung TV)</td></tr>
      <tr><td><strong>Jellyseerr</strong></td><td>default</td><td>Media request management UI</td><td>Users request content → Radarr/Sonarr pick it up</td></tr>
      <tr><td><strong>Radarr</strong></td><td>default</td><td>Movie automation &amp; library management</td><td>Monitors NZB/torrent indexers, downloads, renames</td></tr>
      <tr><td><strong>Sonarr</strong></td><td>default</td><td>TV show automation</td><td>Same as Radarr but for TV series</td></tr>
      <tr><td><strong>Prowlarr</strong></td><td>default</td><td>Unified torrent/NZB indexer</td><td>Single config point, syncs to Radarr/Sonarr</td></tr>
      <tr><td><strong>qBittorrent</strong></td><td>default</td><td>Torrent download client</td><td>Fixed IP: 10.57.57.102 (Cilium)</td></tr>
      <tr><td><strong>n8n</strong></td><td>default</td><td>Workflow automation (no-code)</td><td>Integrations: GitHub, webhooks, notifications</td></tr>
      <tr><td><strong>Authentik outpost</strong></td><td>default</td><td>SSO proxy for K8s-hosted apps</td><td>Connects to Authentik instance on VPS</td></tr>
    </tbody>
  </table>

  <h2>Key Cluster Commands</h2>
  <pre>kubectl get nodes                          # check node status
kubectl get pods -A | grep -v Running      # find problem pods
kubectl get helmreleases -A                # all Helm releases + status
task reconcile                             # force Flux sync

# Node operations
task talos:apply-node IP=10.57.57.80       # apply Talos config
task talos:upgrade-node IP=10.57.57.80     # upgrade Talos version
task talos:upgrade-k8s                     # upgrade Kubernetes</pre>
</div>

<!-- ══════════════════════════════════════════
     PAGE 7 — NETWORKING
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">6. Networking &amp; Access Strategy</h1>
  </div>

  <div class="diagram-wrap">
    <svg width="155mm" height="90mm" viewBox="0 0 580 340" xmlns="http://www.w3.org/2000/svg" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
      <defs>
        <marker id="arr2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10z" fill="#455a64"/>
        </marker>
      </defs>

      <!-- Legend -->
      <rect x="390" y="10" width="180" height="82" rx="6" fill="#fafafa" stroke="#ddd"/>
      <text x="480" y="28" text-anchor="middle" font-size="10" font-weight="700" fill="#333">Legend</text>
      <rect x="400" y="37" width="16" height="4" fill="#ff9800"/>
      <text x="422" y="42" font-size="9" fill="#555">Cloudflare Tunnel (public)</text>
      <rect x="400" y="52" width="16" height="4" fill="#43a047"/>
      <text x="422" y="57" font-size="9" fill="#555">Tailscale VPN (management)</text>
      <rect x="400" y="67" width="16" height="4" fill="#1565c0"/>
      <text x="422" y="72" font-size="9" fill="#555">Internal LAN (10.57.57.x)</text>
      <rect x="400" y="82" width="16" height="4" fill="#9c27b0" stroke-dasharray="4,2"/>
      <text x="422" y="87" font-size="9" fill="#555">DNS (k8s-gateway)</text>

      <!-- Public user -->
      <ellipse cx="75" cy="50" rx="60" ry="24" fill="#eceff1" stroke="#90a4ae" stroke-width="1.5"/>
      <text x="75" y="55" text-anchor="middle" font-size="11" font-weight="700" fill="#455a64">Public User</text>

      <!-- Cloudflare -->
      <rect x="200" y="28" width="120" height="44" rx="8" fill="#fff3e0" stroke="#ff9800" stroke-width="2"/>
      <text x="260" y="48" text-anchor="middle" font-size="11" font-weight="700" fill="#e65100">Cloudflare</text>
      <text x="260" y="63" text-anchor="middle" font-size="8.5" fill="#bf360c">DNS · WAF · DDoS</text>

      <!-- VPS Traefik -->
      <rect x="10" y="140" width="130" height="44" rx="8" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5"/>
      <text x="75" y="160" text-anchor="middle" font-size="10.5" font-weight="700" fill="#0d47a1">VPS Traefik</text>
      <text x="75" y="175" text-anchor="middle" font-size="8" fill="#1565c0">TLS termination</text>

      <!-- CF Tunnel (K8s) -->
      <rect x="170" y="140" width="145" height="44" rx="8" fill="#f3e5f5" stroke="#7b1fa2" stroke-width="1.5"/>
      <text x="242" y="160" text-anchor="middle" font-size="10.5" font-weight="700" fill="#4a148c">CF Tunnel Agent</text>
      <text x="242" y="175" text-anchor="middle" font-size="8" fill="#6a1b9a">runs inside K8s cluster</text>

      <!-- Tailscale Node -->
      <rect x="350" y="140" width="130" height="44" rx="8" fill="#e8f5e9" stroke="#43a047" stroke-width="1.5"/>
      <text x="415" y="160" text-anchor="middle" font-size="10.5" font-weight="700" fill="#1b5e20">Tailscale</text>
      <text x="415" y="175" text-anchor="middle" font-size="8" fill="#2e7d32">100.x.x.x · MagicDNS</text>

      <!-- k8s-gateway -->
      <rect x="170" y="248" width="145" height="44" rx="8" fill="#ede7f6" stroke="#9c27b0" stroke-width="1.5" stroke-dasharray="5,3"/>
      <text x="242" y="268" text-anchor="middle" font-size="10.5" font-weight="700" fill="#4a148c">k8s-gateway</text>
      <text x="242" y="283" text-anchor="middle" font-size="8" fill="#6a1b9a">*.merox.dev → Cilium LB IPs</text>

      <!-- Pi-hole -->
      <rect x="350" y="248" width="130" height="44" rx="8" fill="#e3f2fd" stroke="#1976d2" stroke-width="1.5" stroke-dasharray="5,3"/>
      <text x="415" y="268" text-anchor="middle" font-size="10.5" font-weight="700" fill="#0d47a1">Pi-hole + Unbound</text>
      <text x="415" y="283" text-anchor="middle" font-size="8" fill="#1565c0">DNS-over-HTTPS · Ad-block</text>

      <!-- Arrows -->
      <!-- User -> CF -->
      <line x1="135" y1="50" x2="200" y2="50" stroke="#ff9800" stroke-width="2" marker-end="url(#arr2)"/>
      <!-- CF -> VPS Traefik -->
      <path d="M200,58 Q140,100 140,140" fill="none" stroke="#ff9800" stroke-width="1.8" marker-end="url(#arr2)"/>
      <!-- CF -> CF Tunnel K8s -->
      <line x1="260" y1="72" x2="260" y2="140" stroke="#ff9800" stroke-width="1.8" stroke-dasharray="5,3" marker-end="url(#arr2)"/>
      <!-- Tailscale VPN lines -->
      <path d="M415,140 Q415,80 260,52" fill="none" stroke="#43a047" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr2)"/>
      <path d="M415,140 Q350,110 140,140" fill="none" stroke="#43a047" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr2)"/>
      <!-- CF Tunnel -> k8s-gateway -->
      <line x1="242" y1="184" x2="242" y2="248" stroke="#9c27b0" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr2)"/>
      <!-- Tailscale -> Pi-hole -->
      <line x1="415" y1="184" x2="415" y2="248" stroke="#1565c0" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr2)"/>

      <!-- Labels on arrows -->
      <text x="160" y="96" font-size="8" fill="#e65100">HTTPS (443)</text>
      <text x="265" y="210" font-size="8" fill="#7b1fa2">internal DNS</text>
    </svg>
    <div class="diagram-caption">Figure 2 — Network access paths: public traffic via Cloudflare Tunnel, management via Tailscale VPN</div>
  </div>

  <div class="two-col">
    <div class="col">
      <h2>Cloudflare Tunnel (Public Access)</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.8;">
        <li>Zero open firewall ports on VPS or homelab</li>
        <li>All <code>*.merox.dev</code> public services route through tunnel</li>
        <li>TLS terminated at Cloudflare edge (free)</li>
        <li>DDoS protection &amp; WAF included</li>
        <li>K8s tunnel agent deployed as pod in cluster</li>
        <li>VPS tunnel runs via Traefik container</li>
      </ul>
    </div>
    <div class="col">
      <h2>Tailscale (Management VPN)</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.8;">
        <li>All nodes (VPS + K8s + Proxmox) in same Tailscale network</li>
        <li>MagicDNS for hostname resolution</li>
        <li>VPS acts as exit node</li>
        <li>Portainer EE &amp; Homepage accessible only via Tailscale</li>
        <li>Longhorn → Garage S3 backups travel over Tailscale</li>
        <li>Prevents accidental public exposure of mgmt interfaces</li>
      </ul>
    </div>
  </div>

  <h2>Internal DNS (k8s-gateway)</h2>
  <p style="font-size:8.5pt;">The <code>k8s-gateway</code> pod resolves <code>*.merox.dev</code> internally to Cilium L2 LoadBalancer IPs, so internal clients use the same URLs as external ones but traffic stays on-LAN (split-horizon DNS).</p>
</div>

<!-- ══════════════════════════════════════════
     PAGE 8 — STORAGE & BACKUP
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">7. Storage &amp; Backup Architecture</h1>
  </div>

  <div class="diagram-wrap">
    <svg width="160mm" height="88mm" viewBox="0 0 600 330" xmlns="http://www.w3.org/2000/svg" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
      <defs>
        <marker id="arr3" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10z" fill="#1565c0"/>
        </marker>
        <marker id="arr3g" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10z" fill="#43a047"/>
        </marker>
      </defs>

      <!-- K8s Apps Layer -->
      <rect x="10" y="10" width="580" height="68" rx="10" fill="#f3e5f5" stroke="#7b1fa2" stroke-width="1.5"/>
      <text x="300" y="30" text-anchor="middle" font-size="12" font-weight="700" fill="#4a148c">Kubernetes Application Pods</text>
      <rect x="25" y="38" width="80" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="65" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">Jellyfin</text>
      <rect x="115" y="38" width="80" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="155" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">Radarr/Sonarr</text>
      <rect x="205" y="38" width="80" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="245" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">Prometheus</text>
      <rect x="295" y="38" width="80" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="335" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">Grafana</text>
      <rect x="385" y="38" width="65" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="417" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">n8n</text>
      <rect x="460" y="38" width="80" height="28" rx="5" fill="#fff" stroke="#9c27b0" stroke-width="1"/>
      <text x="500" y="57" text-anchor="middle" font-size="9" font-weight="600" fill="#4a148c">Authentik</text>

      <!-- Longhorn -->
      <rect x="60" y="118" width="230" height="54" rx="8" fill="#e3f2fd" stroke="#1565c0" stroke-width="2"/>
      <text x="175" y="140" text-anchor="middle" font-size="12" font-weight="700" fill="#0d47a1">Longhorn</text>
      <text x="175" y="157" text-anchor="middle" font-size="9" fill="#1565c0">Distributed block storage (3-way replicas)</text>
      <text x="175" y="169" text-anchor="middle" font-size="8.5" fill="#1565c0">Daily backup at 02:00 → Garage S3</text>

      <!-- NAS NFS -->
      <rect x="330" y="118" width="185" height="54" rx="8" fill="#e8f5e9" stroke="#43a047" stroke-width="1.5"/>
      <text x="422" y="140" text-anchor="middle" font-size="12" font-weight="700" fill="#1b5e20">Synology NAS</text>
      <text x="422" y="157" text-anchor="middle" font-size="9" fill="#2e7d32">NFS PVs (media files)</text>
      <text x="422" y="169" text-anchor="middle" font-size="8.5" fill="#2e7d32">IP: 10.57.57.201 · RAID1</text>

      <!-- Arrows: pods -> longhorn/NAS -->
      <line x1="175" y1="78" x2="175" y2="118" stroke="#7b1fa2" stroke-width="1.8" marker-end="url(#arr3)"/>
      <line x1="422" y1="78" x2="422" y2="118" stroke="#7b1fa2" stroke-width="1.8" marker-end="url(#arr3g)"/>

      <!-- Garage S3 on VPS -->
      <rect x="60" y="232" width="230" height="54" rx="8" fill="#fff3e0" stroke="#ff9800" stroke-width="2"/>
      <text x="175" y="254" text-anchor="middle" font-size="12" font-weight="700" fill="#e65100">Garage S3</text>
      <text x="175" y="271" text-anchor="middle" font-size="9" fill="#bf360c">Oracle Cloud VPS  ·  /srv/docker/oracle-cloud/garage/</text>
      <text x="175" y="283" text-anchor="middle" font-size="8.5" fill="#bf360c">Off-site S3-compatible object storage</text>

      <!-- DB Backups -->
      <rect x="330" y="232" width="185" height="54" rx="8" fill="#fce4ec" stroke="#c62828" stroke-width="1.5"/>
      <text x="422" y="254" text-anchor="middle" font-size="12" font-weight="700" fill="#b71c1c">DB Backups</text>
      <text x="422" y="271" text-anchor="middle" font-size="9" fill="#c62828">/srv/backups/  ·  pg_dump</text>
      <text x="422" y="283" text-anchor="middle" font-size="8.5" fill="#c62828">Authentik + Joplin  ·  7-day retention</text>

      <!-- Arrows: Longhorn -> Garage -->
      <path d="M175,172 L175,232" fill="none" stroke="#1565c0" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr3)"/>
      <text x="178" y="205" font-size="8.5" fill="#1565c0">S3 API (Tailscale)</text>
      <!-- NAS -> DB Backups (via pg_dump on VPS) -->
      <path d="M422,172 L422,232" fill="none" stroke="#c62828" stroke-width="1.8" stroke-dasharray="5,3" marker-end="url(#arr3)"/>
      <text x="426" y="205" font-size="8.5" fill="#c62828">pg_dump cron</text>
    </svg>
    <div class="diagram-caption">Figure 3 — Storage layers and backup data flows (Longhorn → Garage S3, databases → /srv/backups)</div>
  </div>

  <div class="two-col">
    <div class="col">
      <h2>Storage Layers</h2>
      <table>
        <thead><tr><th>Layer</th><th>Technology</th><th>Used For</th></tr></thead>
        <tbody>
          <tr><td>Block (replicated)</td><td>Longhorn</td><td>App config, databases, state</td></tr>
          <tr><td>File (shared NFS)</td><td>Synology DS223+</td><td>Media files, large datasets</td></tr>
          <tr><td>Object (S3)</td><td>Garage (VPS)</td><td>Longhorn snapshot backups</td></tr>
        </tbody>
      </table>
    </div>
    <div class="col">
      <h2>Backup Schedule</h2>
      <table>
        <thead><tr><th>What</th><th>When</th><th>Where</th></tr></thead>
        <tbody>
          <tr><td>Longhorn volumes</td><td>Daily 02:00</td><td>Garage S3 (off-site VPS)</td></tr>
          <tr><td>Authentik PostgreSQL</td><td>Manual (pre-change)</td><td>/srv/backups/authentik/</td></tr>
          <tr><td>Joplin PostgreSQL</td><td>Automatic cron</td><td>/srv/backups/</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="callout danger">
    <strong>Critical — Back up age.key separately</strong>
    <code>/srv/kubernetes/infrastructure/age.key</code> is the SOPS master decryption key. If lost, all encrypted K8s secrets (Cloudflare token, Authentik secrets, Longhorn S3 credentials) become unrecoverable. Keep an offline copy.
  </div>
</div>

<!-- ══════════════════════════════════════════
     PAGE 9 — GITOPS + AUTOMATION
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">8. GitOps &amp; Automation</h1>
  </div>

  <div class="diagram-wrap">
    <svg width="155mm" height="62mm" viewBox="0 0 580 232" xmlns="http://www.w3.org/2000/svg" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
      <defs>
        <marker id="arr4" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10z" fill="#1565c0"/>
        </marker>
      </defs>

      <!-- Dev Workstation -->
      <rect x="10" y="80" width="110" height="50" rx="8" fill="#e8f5e9" stroke="#43a047" stroke-width="1.5"/>
      <text x="65" y="102" text-anchor="middle" font-size="10" font-weight="700" fill="#1b5e20">git push</text>
      <text x="65" y="118" text-anchor="middle" font-size="8.5" fill="#2e7d32">Developer workstation</text>

      <!-- GitHub -->
      <rect x="160" y="80" width="110" height="50" rx="8" fill="#fff" stroke="#24292e" stroke-width="2"/>
      <text x="215" y="102" text-anchor="middle" font-size="10.5" font-weight="700" fill="#24292e">GitHub</text>
      <text x="215" y="118" text-anchor="middle" font-size="8.5" fill="#555">meroxdotdev/infrastructure</text>

      <!-- Flux Source Controller -->
      <rect x="310" y="20" width="125" height="50" rx="8" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5"/>
      <text x="372" y="42" text-anchor="middle" font-size="9.5" font-weight="700" fill="#0d47a1">Flux Source</text>
      <text x="372" y="56" text-anchor="middle" font-size="8" fill="#1565c0">Controller · polls GitHub</text>

      <!-- Flux Kustomize Controller -->
      <rect x="310" y="100" width="125" height="50" rx="8" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5"/>
      <text x="372" y="122" text-anchor="middle" font-size="9.5" font-weight="700" fill="#0d47a1">Kustomize</text>
      <text x="372" y="136" text-anchor="middle" font-size="8" fill="#1565c0">Controller · applies manifests</text>

      <!-- Helm Controller -->
      <rect x="310" y="170" width="125" height="50" rx="8" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5"/>
      <text x="372" y="192" text-anchor="middle" font-size="9.5" font-weight="700" fill="#0d47a1">Helm</text>
      <text x="372" y="206" text-anchor="middle" font-size="8" fill="#1565c0">Controller · deploys charts</text>

      <!-- K8s Cluster -->
      <rect x="475" y="80" width="100" height="120" rx="8" fill="#f3e5f5" stroke="#7b1fa2" stroke-width="1.5"/>
      <text x="525" y="105" text-anchor="middle" font-size="10" font-weight="700" fill="#4a148c">K8s</text>
      <text x="525" y="120" text-anchor="middle" font-size="10" font-weight="700" fill="#4a148c">Cluster</text>
      <text x="525" y="140" text-anchor="middle" font-size="8.5" fill="#6a1b9a">Running</text>
      <text x="525" y="153" text-anchor="middle" font-size="8.5" fill="#6a1b9a">Workloads</text>
      <text x="525" y="166" text-anchor="middle" font-size="8.5" fill="#6a1b9a">+ SOPS</text>
      <text x="525" y="179" text-anchor="middle" font-size="8.5" fill="#6a1b9a">decryption</text>

      <!-- Renovate -->
      <rect x="160" y="170" width="110" height="50" rx="8" fill="#fff8e1" stroke="#ff9800" stroke-width="1.5"/>
      <text x="215" y="192" text-anchor="middle" font-size="9.5" font-weight="700" fill="#e65100">Renovate Bot</text>
      <text x="215" y="206" text-anchor="middle" font-size="8" fill="#bf360c">auto PR for updates</text>

      <!-- Arrows -->
      <line x1="120" y1="105" x2="160" y2="105" stroke="#43a047" stroke-width="2" marker-end="url(#arr4)"/>
      <path d="M270,95 L310,65" fill="none" stroke="#1565c0" stroke-width="1.8" marker-end="url(#arr4)"/>
      <path d="M270,105 L310,120" fill="none" stroke="#1565c0" stroke-width="1.8" marker-end="url(#arr4)"/>
      <path d="M270,115 L310,185" fill="none" stroke="#1565c0" stroke-width="1.8" marker-end="url(#arr4)"/>
      <line x1="435" y1="125" x2="475" y2="125" stroke="#7b1fa2" stroke-width="2" marker-end="url(#arr4)"/>
      <line x1="435" y1="145" x2="475" y2="145" stroke="#7b1fa2" stroke-width="2" marker-end="url(#arr4)"/>
      <line x1="435" y1="170" x2="475" y2="165" stroke="#7b1fa2" stroke-width="2" marker-end="url(#arr4)"/>
      <path d="M215,170 L215,130" fill="none" stroke="#ff9800" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr4)"/>
    </svg>
    <div class="diagram-caption">Figure 4 — FluxCD GitOps pipeline: git push triggers Flux reconciliation, Renovate automates dependency updates</div>
  </div>

  <div class="two-col">
    <div class="col">
      <h2>FluxCD Pipeline</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.9;">
        <li>Source Controller polls GitHub every 1 min</li>
        <li>Kustomize Controller applies <code>kubernetes/</code> manifests</li>
        <li>Helm Controller reconciles all HelmRelease resources</li>
        <li>SOPS/AGE decrypts secrets at apply time (age.key in-cluster)</li>
        <li>Drift detection: Flux auto-reverts manual kubectl changes</li>
        <li>Force sync: <code>task reconcile</code></li>
      </ul>
    </div>
    <div class="col">
      <h2>Renovate Automation</h2>
      <ul style="padding-left:4mm; font-size:8.5pt; line-height:1.9;">
        <li>Runs every weekend via GitHub Actions</li>
        <li>Opens PRs for: Helm chart updates, container image tags</li>
        <li>Also tracks: Talos + Kubernetes versions (<code>.mise.toml</code>)</li>
        <li>Config: <code>.renovaterc.json5</code></li>
        <li>Tags annotated with <code># renovate:</code> in manifests</li>
        <li>VPS Ansible also updated via Renovate</li>
      </ul>
    </div>
  </div>

  <h2>Secrets Management (SOPS/AGE)</h2>
  <pre>sops kubernetes/apps/&lt;namespace&gt;/&lt;app&gt;/app/secret.sops.yaml   # edit secret
find . -name "*.sops.*" -exec sops updatekeys {} \;             # rotate AGE key</pre>
</div>

<!-- ══════════════════════════════════════════
     PAGE 10 — AI AGENTS + SECURITY
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">9. AI Agents — OpenClaw</h1>
  </div>

  <p>OpenClaw is an AI agent framework running Claude-powered agents on the VPS. Agents are triggered via <strong>Telegram bot</strong> or internal cron schedules. The <code>infra</code> agent can run <code>kubectl</code> and <code>docker</code> commands remotely.</p>

  <table>
    <thead><tr><th>Agent</th><th>Trigger</th><th>Purpose</th></tr></thead>
    <tbody>
      <tr><td><strong>news</strong></td><td>Cron + Telegram</td><td>Daily briefing — HackerNews + RSS feeds, summarised by Claude</td></tr>
      <tr><td><strong>blog</strong></td><td>Telegram</td><td>Writes and publishes posts to merox.dev via GitHub Actions</td></tr>
      <tr><td><strong>infra</strong></td><td>Telegram</td><td>Runs <code>kubectl</code> / <code>docker</code> commands — natural language infra management</td></tr>
      <tr><td><strong>costs</strong></td><td>Telegram</td><td>Infrastructure cost tracking and reporting</td></tr>
      <tr><td><strong>design</strong></td><td>Telegram</td><td>Visual content generation</td></tr>
      <tr><td><strong>orchestrator</strong></td><td>Internal</td><td>Routes messages between agents + handles scheduled tasks</td></tr>
      <tr><td><strong>dashboard</strong></td><td>Internal cron</td><td>Updates agents.cloud.merox.dev nightly</td></tr>
      <tr><td><strong>renovate</strong></td><td>Internal</td><td>Git dependency sync + PR creation</td></tr>
    </tbody>
  </table>

  <pre># Agent status &amp; management
XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  sudo -u openclaw systemctl --user status openclaw-gateway

sudo -u openclaw journalctl --user -u openclaw-gateway -f
tail -f /home/openclaw/.openclaw/logs/*.log 2>/dev/null</pre>

  <div class="sep"></div>

  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">10. Security Model</h1>
  </div>

  <div class="two-col">
    <div class="col">
      <h2>Secret Handling</h2>
      <table>
        <thead><tr><th>Secret Type</th><th>Method</th></tr></thead>
        <tbody>
          <tr><td>K8s secrets</td><td>SOPS/AGE encrypted <code>*.sops.yaml</code></td></tr>
          <tr><td>VPS Ansible secrets</td><td>Ansible Vault (<code>vps/</code>)</td></tr>
          <tr><td>Docker env vars</td><td><code>.env</code> file (gitignored)</td></tr>
          <tr><td>Agent API keys</td><td><code>.openclaw/.env</code> (gitignored)</td></tr>
          <tr><td>Talos bootstrap</td><td><code>talsecret.sops.yaml</code> (SOPS)</td></tr>
        </tbody>
      </table>
    </div>
    <div class="col">
      <h2>Access Control</h2>
      <table>
        <thead><tr><th>Layer</th><th>Mechanism</th></tr></thead>
        <tbody>
          <tr><td>External HTTP</td><td>Cloudflare Tunnel (no open ports)</td></tr>
          <tr><td>Management</td><td>Tailscale mesh VPN</td></tr>
          <tr><td>SSO</td><td>Authentik (Google-only, no signups)</td></tr>
          <tr><td>K8s RBAC</td><td>Talos native (hardened by default)</td></tr>
          <tr><td>Network policy</td><td>Cilium NetworkPolicy</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════════
     PAGE 11 — DISASTER RECOVERY
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">11. Disaster Recovery</h1>
  </div>

  <div class="callout warning">
    <strong>Prerequisites (have these ready before any DR scenario)</strong>
    <code>age.key</code> (SOPS master key) · Ansible Vault password · Valid Tailscale auth key · Cloudflare API token
  </div>

  <h2>DR Scenario Matrix</h2>
  <table>
    <thead><tr><th>Scenario</th><th>Action</th><th>RTO</th></tr></thead>
    <tbody>
      <tr><td><strong>K8s cluster lost</strong> (nodes dead)</td><td>DR.md — provision DR VMs, bootstrap Talos, restore Longhorn from S3</td><td>~35 min</td></tr>
      <tr><td><strong>VPS lost</strong> (Oracle reclaims free tier)</td><td><code>cd vps &amp;&amp; make dr-full</code> → <code>make restore</code></td><td>~15 min</td></tr>
      <tr><td><strong>Full rebuild from scratch</strong></td><td>DEPLOY.md: Phase 1 (VPS) → Phase 2 (K8s) → Phase 3 (Agent)</td><td>~50 min</td></tr>
      <tr><td><strong>Single node lost</strong></td><td>Provision replacement VM in Proxmox, <code>task talos:apply-node</code></td><td>~10 min</td></tr>
      <tr><td><strong>New hardware</strong> (different IPs)</td><td>Edit <code>talconfig.yaml</code>, <code>cluster-vars.yaml</code>, <code>cilium/networks.yaml</code></td><td>~20 min</td></tr>
      <tr><td><strong>HelmRelease stuck</strong></td><td><code>flux suspend/resume helmrelease &lt;name&gt;</code></td><td>&lt;5 min</td></tr>
      <tr><td><strong>VPS only</strong> (K8s OK)</td><td><code>make dr-full</code> on any machine with the repo + vault pass</td><td>~15 min</td></tr>
    </tbody>
  </table>

  <h2>Full Rebuild Steps (Phase 1 → 3)</h2>
  <ol class="steps">
    <li><strong>Phase 1 — VPS (~15 min)</strong><br/><code>cd vps &amp;&amp; make dr-full</code> — provisions Hetzner fallback VPS + deploys all Docker services via cloud-init.<br/>Then: <code>make restore</code> to restore Joplin + Authentik databases from backups.</li>
    <li><strong>Phase 2 — Kubernetes (~20 min)</strong><br/>Copy <code>age.key</code> to repo. Edit <code>talos/talconfig.yaml</code> (node IPs, install disk) and <code>kubernetes/components/common/cluster-vars.yaml</code>.<br/>Run: <code>task bootstrap:talos</code> → <code>task bootstrap:apps</code> → <code>task restore:longhorn</code></li>
    <li><strong>Phase 3 — AI Agents (~15 min)</strong><br/>Create <code>openclaw</code> user, run <code>claude login</code>, run <code>openclaw onboard</code>, fill in <code>.env</code>, enable systemd service.</li>
    <li><strong>Validation</strong><br/><code>kubectl get nodes</code> → all Ready · <code>docker ps | wc -l</code> → ~16 containers · Test Telegram bot reply.</li>
  </ol>

  <h2>Troubleshooting Quick Reference</h2>
  <pre># Flux not reconciling
flux get sources git -A
flux logs --level=error
flux reconcile kustomization cluster-apps --with-source

# HelmRelease stuck
kubectl get helmreleases -A | grep -v True
flux suspend helmrelease &lt;name&gt; -n &lt;namespace&gt;
flux resume  helmrelease &lt;name&gt; -n &lt;namespace&gt;

# Pod issues
kubectl -n &lt;ns&gt; describe pod &lt;pod&gt;
kubectl -n &lt;ns&gt; logs &lt;pod&gt; --previous

# Node unreachable
talosctl -n &lt;node-ip&gt; health
talosctl -n &lt;node-ip&gt; dmesg</pre>
</div>

<!-- ══════════════════════════════════════════
     PAGE 12 — EXTERNAL DEPS + COSTS
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">12. External Dependencies &amp; Costs</h1>
  </div>

  <table>
    <thead><tr><th>Service</th><th>Purpose</th><th>Cost</th><th>Tier</th></tr></thead>
    <tbody>
      <tr><td><strong>Cloudflare</strong></td><td>DNS · CDN · Tunnel · WAF · Pages (blog CI/CD)</td><td>€0/mo</td><td><span class="td-badge badge-green">Free</span></td></tr>
      <tr><td><strong>Tailscale</strong></td><td>Management VPN mesh (all nodes + VPS)</td><td>€0/mo</td><td><span class="td-badge badge-green">Free</span></td></tr>
      <tr><td><strong>Oracle Cloud</strong></td><td>Primary VPS (4 vCPU ARM, 24GB RAM, 200GB)</td><td>€0/mo</td><td><span class="td-badge badge-green">Always Free</span></td></tr>
      <tr><td><strong>Hetzner VPS</strong></td><td>Fallback VPS — provision only if Oracle free tier lost</td><td>€5.39/mo</td><td><span class="td-badge badge-orange">On-demand</span></td></tr>
      <tr><td><strong>Anthropic / Claude</strong></td><td>AI model powering OpenClaw agents (Claude Pro OAuth)</td><td>~$20/mo</td><td><span class="td-badge badge-blue">Claude Pro</span></td></tr>
      <tr><td><strong>GitHub</strong></td><td>Repos + GitHub Actions (CI for blog, Renovate)</td><td>€0/mo</td><td><span class="td-badge badge-green">Free</span></td></tr>
      <tr><td><strong>Let's Encrypt</strong></td><td>HTTPS certificates (auto-renew via cert-manager)</td><td>€0/mo</td><td><span class="td-badge badge-green">Free</span></td></tr>
      <tr><td><strong>Proxmox</strong></td><td>Hypervisor for K8s VMs (runs on own hardware)</td><td>€0/mo</td><td><span class="td-badge badge-teal">Own HW</span></td></tr>
      <tr><td><strong>Synology DS223+</strong></td><td>NAS — NFS for K8s + DB backup storage</td><td>€0/mo</td><td><span class="td-badge badge-teal">Own HW</span></td></tr>
    </tbody>
  </table>

  <div class="diagram-wrap" style="margin-top:5mm;">
    <svg width="120mm" height="42mm" viewBox="0 0 450 158" xmlns="http://www.w3.org/2000/svg" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
      <!-- Cost breakdown visual bar -->
      <text x="225" y="18" text-anchor="middle" font-size="11" font-weight="700" fill="#333">Monthly Infrastructure Cost Breakdown</text>

      <!-- Bar: Free services -->
      <rect x="20" y="35" width="320" height="26" rx="4" fill="#43a047"/>
      <text x="30" y="52" font-size="9.5" font-weight="600" fill="#fff">Free services (Cloudflare, Oracle, Tailscale, GitHub, Let's Encrypt) — €0</text>

      <!-- Bar: Claude Pro -->
      <rect x="20" y="70" width="90" height="26" rx="4" fill="#1565c0"/>
      <text x="30" y="87" font-size="9.5" font-weight="600" fill="#fff">Claude Pro — ~$20</text>

      <!-- Bar: Hetzner (optional) -->
      <rect x="20" y="105" width="48" height="26" rx="4" fill="#ff9800" stroke="#e65100" stroke-dasharray="4,2"/>
      <text x="75" y="122" font-size="9" fill="#e65100">(optional) Hetzner fallback — €5.39</text>

      <text x="225" y="148" text-anchor="middle" font-size="8.5" fill="#888">Normal monthly total: ~$20 USD  |  With Hetzner fallback: ~€25.39</text>
    </svg>
  </div>

  <div class="sep"></div>

  <h2>Repository Map</h2>
  <table>
    <thead><tr><th>What</th><th>GitHub Repo</th><th>Local Path</th></tr></thead>
    <tbody>
      <tr><td>K8s Flux manifests + Talos config</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/</td></tr>
      <tr><td>Ansible + Terraform VPS DR</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/vps/</td></tr>
      <tr><td>Docker Compose VPS services</td><td>meroxdotdev/cloudlab-merox</td><td>/srv/docker/oracle-cloud/</td></tr>
      <tr><td>OpenClaw agent config + infra skill</td><td>meroxdotdev/infrastructure</td><td>/srv/kubernetes/infrastructure/agent/</td></tr>
      <tr><td>Blog (Astro)</td><td>meroxdotdev/merox (private)</td><td>/srv/merox/</td></tr>
    </tbody>
  </table>
</div>

<!-- ══════════════════════════════════════════
     PAGE 13 — DAY-TO-DAY OPERATIONS
══════════════════════════════════════════ -->
<div class="page">
  <div class="section-header">
    <span class="section-icon"></span>
    <h1 class="section-title">13. Day-to-Day Operations Quick Reference</h1>
  </div>

  <div class="two-col">
    <div class="col">
      <h2>Kubernetes Cluster</h2>
      <pre>kubectl get nodes
kubectl get pods -A | grep -v Running
kubectl get helmreleases -A
kubectl get kustomizations -A
cilium status

task reconcile   # force Flux sync

# Talos node ops
task talos:generate-config
task talos:apply-node IP=10.57.57.80
task talos:upgrade-node IP=10.57.57.80
task talos:upgrade-k8s</pre>

      <h2>Flux Troubleshooting</h2>
      <pre>flux get sources git -A
flux get kustomizations -A
flux logs --level=error
flux reconcile kustomization \
  cluster-apps --with-source

# HelmRelease stuck
flux suspend helmrelease &lt;name&gt; -n &lt;ns&gt;
flux resume  helmrelease &lt;name&gt; -n &lt;ns&gt;</pre>

      <h2>Longhorn Storage</h2>
      <pre>kubectl -n longhorn-system get volumes
kubectl -n longhorn-system get nodes.longhorn.io

# Remove orphaned replicas
kubectl get orphan -n longhorn-system -o name | \
  xargs kubectl delete -n longhorn-system</pre>
    </div>

    <div class="col">
      <h2>VPS / Docker Services</h2>
      <pre>cd /srv/docker/oracle-cloud

docker ps
docker ps | grep -v Up
docker logs &lt;name&gt; -f
docker compose up -d

cd vps/
make health-check
make setup
make update
make restore
make dr-full</pre>

      <h2>Node Maintenance</h2>
      <pre># Drain node before maintenance
kubectl drain &lt;node&gt; \
  --ignore-daemonsets \
  --delete-emptydir-data

# After maintenance
kubectl uncordon &lt;node&gt;

# Wait 1-2h between disk swaps
# for Longhorn replica rebuild</pre>

      <h2>Garage S3</h2>
      <pre>docker exec garage /garage status
docker exec garage /garage bucket list
kubectl -n longhorn-system \
  get secret minio-secret</pre>

      <h2>SOPS Secrets</h2>
      <pre>sops kubernetes/apps/&lt;ns&gt;/&lt;app&gt;/\
  app/secret.sops.yaml

# After AGE key rotation
find . -name "*.sops.*" \
  -exec sops updatekeys {} \;</pre>
    </div>
  </div>

  <div class="callout" style="margin-top:3mm;">
    <strong>Full Documentation</strong>
    Complete index: <code>/srv/kubernetes/infrastructure/README.md</code> · Full rebuild guide: <code>DEPLOY.md</code> · K8s DR procedure: <code>DR.md</code> · Jellyfin post-restore: <code>docs/jellyfin-post-restore.md</code>
  </div>

  <!-- Final signature block -->
  <div style="margin-top:8mm; padding:4mm 5mm; background:#0d1b2a; border-radius:6px; display:flex; justify-content:space-between; align-items:center;">
    <div>
      <div style="font-size:10pt; font-weight:700; color:#fff;">Robert Melcher</div>
      <div style="font-size:8.5pt; color:#90caf9;">HPC System Administrator @ Forvia</div>
    </div>
    <div style="text-align:right;">
      <div style="font-size:8.5pt; color:#80cbc4;">merox.dev</div>
      <div style="font-size:8pt; color:#78909c;">github.com/meroxdotdev</div>
    </div>
  </div>
</div>

</body>
</html>
"""

with open("/tmp/infra_overview.html", "w") as f:
    f.write(HTML)

import weasyprint
print("Generating PDF...")
weasyprint.HTML(filename="/tmp/infra_overview.html").write_pdf(
    "/srv/kubernetes/infrastructure/docs/infra-overview-2026.pdf"
)
print("Done: /srv/kubernetes/infrastructure/docs/infra-overview-2026.pdf")

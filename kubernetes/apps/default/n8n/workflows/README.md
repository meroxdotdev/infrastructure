# n8n workflows

A reference export of the one workflow n8n still runs, so it is reviewable in
git instead of living only inside a Longhorn PVC.

⚠️ **Not applied by Flux.** n8n owns its own state; nothing here is reconciled.
Editing a file in this directory changes nothing on the cluster — it is a
snapshot for review, diffing and disaster recovery, in the same spirit as
[`proxmox/pve-2/etc/`](../../../../../proxmox/pve-2/etc/). The running copy is
authoritative; re-export after changing anything in the n8n UI.

## What n8n is for now

`daily-news-digest` — four RSS feeds in, one Claude call, one Telegram message,
daily at 14:00. That is the whole of it, and it is why n8n is still here.

## The alert pipeline that used to be here

Four workflows — `alertmanager-webhook`, `flux-webhook`, `hardware-webhook` and
the shared `triage-and-notify` — took an alert, handed it to a local model on
the Ollama VM for a one-line summary, and forwarded it to Telegram.

Deactivated and removed on 2026-09-09. Alertmanager and Flux have spoken
Telegram natively since 2026-09-07, so from that day the chain was a second path
to the same chat, with three more processes able to fail silently between an
alert firing and the phone buzzing. The Ollama VM was its only consumer and went
with it.

The exports are not kept here: they describe a pipeline that should not be
rebuilt. A full export of all eight workflows as they stood that day is on pve-2
at `/media/backups/tools/n8n/workflows-2026-09-09.json`, inside the backup
chain rather than in this public repository — the JSON carries the Telegram
chat id and webhook paths.

## Re-importing

n8n UI → Workflows → Import from File.

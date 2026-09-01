# n8n workflows

Reference exports of the five active workflows, so the alerting pipeline is
reviewable in git instead of living only inside a Longhorn PVC.

⚠️ **These are not applied by Flux.** n8n owns its own state; nothing here is
reconciled. Editing a file in this directory changes nothing on the cluster —
it is a snapshot for review, diffing and disaster recovery, in the same spirit
as [`proxmox/r730xd/etc/`](../../../../../proxmox/r730xd/etc/). The running copy
is authoritative; re-export after changing anything in the n8n UI.

## The alert pipeline

```
Alertmanager ─┐
Flux          ├─▶ webhook ─▶ format message ─▶ triage-and-notify ─▶ Telegram
hardware      ─┘                                      │
                                                      └─▶ Ollama on the LAN
                                                          (qwen3:4b-instruct)
```

`triage-and-notify` is shared: each webhook formats an alert into a single
`message` string, hands it over, and the model reduces it to one line.

`daily-news-digest` is unrelated to alerting — RSS in, Claude Haiku out, same
Telegram chat.

## Re-importing

n8n UI → Workflows → Import from File. Then, per workflow:

- reattach credentials (Telegram, header auth) — they are referenced by name
  here but never exported
- put the real Telegram chat ID back where the redaction marker is
- webhook IDs regenerate on import; the `path` values are what the senders
  actually post to, and those are preserved

## What is redacted

| Field | Why |
|---|---|
| `chatId` | personal Telegram identifier |
| `webhookId` | internal, regenerated on import, no value in publishing |

Credentials are never part of an n8n export — only their names and types.

The webhook `path` values are kept. `n8n.k8s.merox.dev` and
`n8n-webhook.k8s.merox.dev` resolve only through pfSense's Unbound host
overrides and do not exist in public DNS, so the endpoints are not reachable
from outside the LAN.

⚠️ **`flux-webhook` has no authentication**, unlike the other two. That is
survivable only because of the DNS boundary above — anything that can reach
the cluster gateway can post fake Flux alerts into the Telegram channel. Worth
adding header auth to match the others.

## 2026-08-21: the triage step was inventing facts

A daily Telegram alert read `TargetDown on db-server-01: 98% unreachable`. No
such host exists — not in the cluster, not in the VM inventory, not in this
repo. The real alert carried three labels and no host name at all, and the
real figure was 50%.

Three faults stacked:

1. `alertmanager-webhook` built its `message` from
   `kubernetes_node || instance || namespace`. `TargetDown` has none of them,
   so the string rendered as `TargetDown on : …` with nothing after `on`.
2. It preferred `annotations.summary` over `annotations.description`. For
   kube-prometheus-stack alerts `summary` is the generic sentence and
   `description` is the one carrying the numbers, so the figures never
   reached the model either.
3. The prompt then said *"You MUST include the specific resource/host name and
   any numbers/percentages"*. Given an alert with neither, a 4B model can only
   comply by inventing both. It did, plausibly enough to be believed.

Fixed by adding `job` and a literal fallback to the identifier chain,
preferring `description`, and rewriting the prompt to forbid supplying
anything the alert does not contain. Verified against the live model: fed the
old string it now repeats it unchanged instead of decorating it.

The lesson is not about this model. An instruction to always report a field is
an instruction to fabricate it whenever it is missing.

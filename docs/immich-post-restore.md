# Immich — Post-Restore & Configuration Reference

Immich's GitOps config (`kubernetes/apps/default/immich/`) handles the
deployment automatically, but a few things are one-time manual steps or live
only in the running Postgres/PVC, not in git.

---

## 1. Architecture

- **immich-server** — official `immich-charts` Helm chart (bjw-s common
  library based, same foundation as every other app in this cluster).
  Machine learning (face/object detection, smart search) is deliberately
  **disabled** (`machine-learning.enabled: false`) to stay light — this
  cluster's only GPU is already dedicated to Jellyfin transcoding. Can be
  re-enabled later by flipping that value if wanted.
- **Valkey** (Redis fork) — bundled by the chart (`valkey.enabled: true`),
  ephemeral (emptyDir) — job queue + cache, not precious data.
- **Postgres** — standalone, NOT CloudNativePG. This cluster has no Postgres
  operator and one single-instance DB didn't justify adding one. Image
  `ghcr.io/tensorchord/cloudnative-vectorchord:15-0.3.0` (Postgres + the
  VectorChord vector-search extension), Longhorn-backed PVC (local disk,
  as recommended — Postgres should never be network storage).

## 2. One-time setup after first deploy

The VectorChord extension isn't auto-created on first boot with a standalone
(non-CNPG) Postgres — run this once, manually, after the `immich-postgres`
pod is up:

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=immich-postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$POD" -- psql -U immich -d immich -c \
  "CREATE EXTENSION IF NOT EXISTS vchord CASCADE; CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;"
```

If this cluster is ever rebuilt from scratch (DR scenario), re-run this after
`immich-postgres` comes back up and before immich-server's migrations run.

## 3. Storage layout (on `pve`, NFS-exported)

| Path                    | Purpose                                              | Mount                       |
| ------------------------ | ----------------------------------------------------- | ---------------------------- |
| `/media/photos/upload`   | Immich's own library — new uploads, thumbnails, encodes | `immich.persistence.library` (static PV, read-write) |
| `/media/photos/external` | Migrated Synology Photos library (read-only import)  | External Library, mounted at `/mnt/external-library` |

The external library was migrated from Synology's
`/volume1/homes/merox/Photos/PhotoLibrary/` (excluding the `@eaDir` thumbnail
cache) via the `media/backups/synology-home` nightly pull — see
[[project_synology_decommission]]. It's intentionally **read-only** and
separate from Immich's own upload location, so Immich never reorganizes or
modifies the original files; it just re-derives albums/dates from EXIF and
folder structure on scan.

**After first deploy**, configure the External Library manually (not
git-managed — Immich has no config-as-code for this): Administration →
Libraries → Create External Library → Import path `/mnt/external-library` →
Scan.

## 4. Backup

Nightly `pg_dump` CronJob (`immich-postgres-backup`, 03:30, after the other
02:xx-03:xx jobs) dumps to `/media/backups/immich-postgres/` on the SAS pool,
gzipped, 30-day retention. This is the DB only (albums, face tags, favorites,
sharing links) — the actual photo files are covered by the SAS pool's own
redundancy (RAIDZ2), same as the rest of the media library.

**Restore**: scale `immich-postgres` to 0, restore the dump into a fresh
Postgres data dir (or `psql < dump.sql` into a freshly-initialized instance
with the extensions already created per step 2), scale back up.

## 5. Explicitly not done here

- Synology Photos is **not** decommissioned — it stays live side-by-side
  until this is verified working end-to-end (mobile upload, browsing,
  thumbnails). See [[project_synology_decommission]] for the full sequencing.
- ML features are off — re-enabling later requires real RAM/CPU budget
  review, not just flipping the value.

# Workstations

How a machine the user works on is organised and backed up. Written for
Claude Code running on one of them: read it fully, then apply it to the machine
you are on. The MacBook is the reference implementation ([macbook/](../macbook/README.md)).

## The rule

| What | Where | Backed up by |
|---|---|---|
| Code — anything with git | `~/Projects/<name>` (Windows: `%USERPROFILE%\Projects\<name>`), flat, one folder per repo | a daily job: one git bundle per repo into Drive `Lab/Repos/<machine>/` |
| Everything else — documents, photos, files | Synology Drive, `Personal/` `Work/` `Lab/` `Shared/` | the Synology Drive client |
| The machine itself | nothing, or the hypervisor's VM backup for a VM | — |

Two places, one mechanism each. Nothing lives in both.

- **Code never goes in Drive.** Drive syncs `.git` mid-write (corrupt repos,
  conflict copies) and uploads `node_modules`/build output that a command
  rebuilds. A `.git` found inside Drive is moved to `Projects/`.
- **Every folder in `Projects/` is a git repo.** A folder without git is either
  `git init`-ed or is not code and goes to Drive.
- **Nothing is duplicated.** Before moving anything into Drive, look for an
  existing copy there (e.g. school files already live in `Shared/Comun/Scoala`).
  Merge into it, never create a second one.
- **Space is precious.** Everything on the NAS goes on to the vault and to
  Oracle. No archives of repos (`.zip`, `.tar.gz`), no build output, no
  `node_modules`, no installers in Drive.

## Drive layout

`homes/merox/Cloud` on the NAS, one folder per role:

| Folder | Holds |
|---|---|
| `Personal/` | own documents: `Acte`, `Apartament`, `Diverse`, … |
| `Work/` | the employer (`Hella/`) and `Clients/<client>/` |
| `Lab/` | learning and side projects: notes, e-books, assets — not code |
| `Shared/` | what someone else sees: `Comun/` (family), `Public/` |

Photos belong in Synology Photos, not in Drive.

## The backup job

Port [backup-repos.sh](../macbook/backup-repos.sh) to the machine, keeping
its behaviour:

- one `<repo>.bundle` per repo (`git bundle create --all`), plus the
  uncommitted work as `refs/backup/worktree`, rewritten only when refs change;
- built outside Drive, then moved into Drive `Lab/Repos/<machine>/` whole, so the Drive
  client uploads it like any other file. No NAS user, no rsync;
- skip a repo the machine adds nothing to (clean, nothing unpushed) when its
  origin is in [github-repos](../truenas/config/github-repos) or is not the user's.

On Windows: Git for Windows ships bash, so the script runs under `bash.exe`
with `SRC`/`DEST` pointed at `%USERPROFILE%\Projects` and the Drive folder.
Schedule it with Task Scheduler, daily, "run as soon as possible after a missed
start". Each machine owns its own `Lab/Repos/<machine>/`: the job deletes
bundles there whose repo is gone, so two machines must never share a folder.

## How to work with the user

- Chat in Romanian, short and scannable. Repo text in English.
- Look first, then propose. Ask before deleting anything that is not provably
  redundant (pushed to a remote, or an identical copy elsewhere); say what was
  checked.
- Record what changed in this repository, not only in chat.

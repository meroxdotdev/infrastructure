# Workstations

How a machine the user works on is organised and backed up. Written for
Claude Code running on one of them: read it fully, then apply it to the machine
you are on.

## The rule

| What | Where | Backed up by |
|---|---|---|
| Code — anything with git | `~/Projects/<name>` (Windows: `%USERPROFILE%\Projects\<name>`), flat, one folder per repo | its git remote: push it. The vault mirrors the user's GitHub repos ([github-repos](../truenas/config/github-repos)) |
| Everything else — documents, photos, files | Synology Drive, `Personal/` `Work/` `Lab/` `Shared/` | the Synology Drive client |
| The machine itself | nothing, or the hypervisor's VM backup for a VM | — |

Two places, one mechanism each. Nothing lives in both.

- **Code never goes in Drive.** Drive syncs `.git` mid-write (corrupt repos,
  conflict copies) and uploads `node_modules`/build output that a command
  rebuilds. A `.git` found inside Drive is moved to `Projects/`.
- **Every folder in `Projects/` is a git repo with a remote.** A folder without
  git is either `git init`-ed and pushed, or is not code and goes to Drive.
  What is not pushed exists only on that machine.
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

## How to work with the user

- Chat in Romanian, short and scannable. Repo text in English.
- Look first, then propose. Ask before deleting anything that is not provably
  redundant (pushed to a remote, or an identical copy elsewhere); say what was
  checked.
- Record what changed in this repository, not only in chat.

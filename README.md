# es-snapshot-restore

A bash tool that migrates indices between two Elasticsearch 6.8 clusters (on AKS) using
**snapshot/restore**.

- **SOURCE**: the old cluster (production). It provides the snapshot: either a new one created on the spot, or an existing one (e.g. from curator).
- **DESTINATION**: the new cluster. It receives the restore by reading the source repository, which is registered on it as **read-only**.

## Requirements

- Linux with `bash` 4+, `curl` and `jq` (`apt-get install -y curl jq` or `yum install -y curl jq`)
- HTTP(S) access to both Elasticsearch clusters (through the ingress)
- On the DESTINATION: the `repository-azure` plugin, with a keystore client that can access the Storage Account (already in place if the repositories exist)

## Usage

```bash
cp config.env.example config.env
chmod 600 config.env
vi config.env                       # URLs, users, repository names...
chmod +x es-snapshot-restore.sh
./es-snapshot-restore.sh            # interactive menu
```

Menu:

1. Check connectivity and prerequisites
2. **Snapshot + Restore**: create a new snapshot **or** list existing ones and pick one, then restore it
3. List snapshots
4. Monitor the last restore
5. Verify indices from the last restore
6. Register read-only repository
7. Revert temporary destination tuning

Each action can also be run directly as a command: `check`, `run`, `list`, `snapshot`, `restore <snapshot>`, `monitor`,
`verify`, `register-repo`, `reset-tuning`. Use `-c other.env` to point to a different configuration file.

Logs and CSV reports go to `./logs`. The state of the last restore is kept in `./state`.

## What happens during a restore

1. The tool reads the snapshot through the destination's read-only repo and filters its indices with `RESTORE_INDICES` (default `*,-.*`).
2. It compares them with the indices and aliases that already exist on the destination. If any already exist, it asks
   whether to skip them, delete them, or cancel (`ON_CONFLICT`).
3. It estimates the disk space and shard count, and compares them with the destination's free disk.
4. It shows a summary and **only proceeds if you type `y` or `Y`**. If indices will be deleted, it asks for a second confirmation.
5. It sends the restore with `include_global_state: false` and **no `index_settings`**, so primaries and replicas stay
   exactly as in the snapshot (3 + 1).
6. It shows progress (primaries and replicas STARTED) until everything is green, then writes a report comparing
   pri/rep/docs with the source.

Ctrl+C during monitoring stops only the monitoring. The restore keeps running on the cluster; use `monitor` to resume watching it.

## Impact on the production cluster (SOURCE)

| Action | Touches the source? |
|---|---|
| Restore | **No**. The destination reads the files directly from the Storage Account |
| List snapshots (`LIST_SNAPSHOTS_FROM=dest`, the default) | **No** |
| Preflight checks | Light reads only (`/`, `_cluster/health`, `GET _snapshot/<repo>`) |
| Create a new snapshot | Yes, only when you choose it and confirm. It is incremental, uses the throttle already configured on the repo, and sets `include_global_state=false` |
| Post-restore verification | `_cat/indices` (read). Disable with `VERIFY_COMPARE_WITH_SOURCE=false` |
| Register the destination repo on the source (optional) | Writes one read-only repository entry |

The tool **never** changes settings, indices, or the repository on the source. It also aborts if the source and the
destination turn out to be the same cluster (it compares `cluster_uuid`).

## Caveats

- **Curator and a snapshot in use**: if curator's `delete_snapshots` deletes the snapshot while the destination is still
  restoring it, the restore fails. Pick a snapshot that is not close to the retention cutoff, or pause the cleanup during
  the restore. For snapshots created by the tool, use a `SNAPSHOT_NAME_PREFIX` that curator's filters won't delete.
- **One snapshot at a time**: ES 6.x allows only one running snapshot per cluster. The tool checks this before creating
  its own, but a curator job that starts right after will fail.
- **Read-only repository**: the source repo must be `readonly: true` on the destination. Two clusters writing to the same
  repository can corrupt it. `check` validates this, and also confirms that the repo points to the same container/base_path.
- **Speed**: in ES 6.x, the default restore read throttle is `max_restore_bytes_per_sec=40mb` **per node**. A repo
  registered by the tool uses `DEST_RO_REPO_MAX_RESTORE_BYTES_PER_SEC` instead (e.g. 200mb). With
  `DEST_TUNE_DURING_RESTORE=true`, the tool also raises recovery concurrency and speed **on the destination** for the
  duration of the restore, and reverts it at the end.
- **nginx ingress**: long-running requests use `wait_for_completion=false`. Even so, listing snapshots and computing the
  size of large snapshots can hit `proxy-read-timeout`. With many indices, the restore request body can hit
  `proxy-body-size` (the script warns if it does).
- **Final cutover**: a common approach is to restore a snapshot with the full history first. Close to the switch-over,
  restore a newer snapshot with `ON_CONFLICT=skip` to bring in only the new indices. Indices still receiving writes on
  the source (e.g. today's index) need separate handling: either `delete` + restore, or reindex just those.

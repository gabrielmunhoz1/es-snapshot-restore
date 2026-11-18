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
6. Register read-only repository (registers the source repository on the destination)

Each action can also be run directly as a command: `check`, `run`, `list`, `snapshot`, `restore <snapshot>`, `monitor`,
`verify`, `register-repo`. Use `-c other.env` to point to a different configuration file.

Logs and CSV reports go to `./logs`. The state of the last restore is kept in `./state`.

## Caveats

- **Curator and a snapshot in use**: if curator's `delete_snapshots` deletes the snapshot while the destination is still
  restoring it, the restore fails. Pick a snapshot that is not close to the retention cutoff. For snapshots created by the tool, use a `SNAPSHOT_NAME_PREFIX` that curator's filters won't delete.
- **One snapshot at a time**: ES 6 version allows only one running snapshot per cluster. The tool checks this before creating
  its own, but a curator job that starts right after will fail.

# HA borg

Sends Home Assistant backups to a [borg](https://www.borgbackup.org/) repository over SSH.
Every backup whose name starts with `backup_prefix` is sent to borg exactly once; after a
successful send only the `keep_local` newest such backups are kept on the device. Manual
backups and pre-update backups are never touched.

The add-on does not create backups itself. A Home Assistant automation does: it calls
`hassio.backup_full` with `compressed: false` and a name starting with the prefix, then starts
the add-on with `hassio.addon_start`. See the example in
[`ha/automation-borg-backup.yaml`](https://github.com/brzd-me/ha-borg-addon/blob/main/ha/automation-borg-backup.yaml).
Uncompressed backups let borg deduplicate them: a typical night adds megabytes, not the full backup size.

## Installation

1. Settings → Add-ons → Add-on Store → ⋮ → Repositories → add
   `https://github.com/brzd-me/ha-borg-addon`, then install **HA borg**.
   (Alternatively copy the `ha-borg` folder to the local add-ons folder: `/addons/ha-borg/`
   on HAOS, `/usr/share/hassio/addons/local/ha-borg/` on Supervised.)
2. In the add-on configuration set `borg_repo` and `borg_passphrase`.
   **Keep a copy of the passphrase outside borg** (e.g. in a password manager): the HA backup
   that contains it is encrypted with that same passphrase.
3. Start the add-on once. The log shows `Public key for the borg server: ssh-ed25519 … ha-borg`.
4. On the borg server add this key to `~/.ssh/authorized_keys` of the user from `borg_repo`,
   restricted to append-only access to this one repository:

   ```
   command="borg serve --append-only --restrict-to-repository /path/to/repo",restrict,from="<HA IP>" ssh-ed25519 … ha-borg
   ```

5. Create the automation from the example. Set its `addon` variable to the add-on slug shown
   on the add-on page (e.g. `1a2b3c4d_ha-borg` when installed from the repository,
   `local_ha-borg` when installed locally), and replace the notify action with your own.

Pruning and compacting the borg repository is left to the borg server (`borg prune
--glob-archives '<archive_prefix>-*'`): with append-only access the add-on cannot delete anything there.

## Options

| Option | Default | Description |
|---|---|---|
| `borg_repo` | — (required) | borg repository, e.g. `ssh://user@borg-server/path/to/repo` |
| `borg_passphrase` | — (required) | Repository passphrase |
| `borg_compression` | `lz4` | borg compression (`--compression`) |
| `backup_prefix` | `borg` | Which HA backups to send (start of the backup name) |
| `archive_prefix` | `ha` | Start of the archive name: `<archive_prefix>-<YYYY-MM-DDTHH:MM>-<slug>` |
| `keep_local` | `2` | How many newest prefixed backups to keep on the device |
| `max_age_hours` | `6` | Error if the newest prefixed backup is older than this |
| `sensor_entity` | `sensor.ha_borg_last_backup` | Sensor that reports the result |
| `sensor_name` | `HA borg: last backup` | Sensor display name |
| `stall_timeout_seconds` | `300` | Seconds without data movement (download, connection to the borg server) treated as a broken connection |

## Sensor

State: `running` while working, then `ok` or `error`. Attributes: `last_run`, `sent`
(archives sent), `added_mb` (new data added to the repository), `error`, `warning`.
The sensor disappears after a Home Assistant restart until the add-on runs again.

## Failures

- Download or borg error: sending stops, nothing is deleted, the unsent backups are retried
  on the next run.
- `sent.json` (the list of sent backups in the add-on data) is corrupt: nothing is done, the
  sensor reports `error`. Deleting the file re-sends all prefixed backups; archives that
  already exist in borg are skipped.

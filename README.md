# HA borg add-on

Home Assistant add-on that sends uncompressed HA backups to a [borg](https://www.borgbackup.org/) repository over SSH, each backup exactly once, keeps only the newest few on the device and reports the result in a sensor. Uncompressed backups deduplicate well: a typical night adds megabytes to the repository instead of the full backup size.

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fbrzd-me%2Fha-borg-addon)

Or: Settings → Add-ons → Add-on Store → ⋮ → Repositories → add `https://github.com/brzd-me/ha-borg-addon`, then install **HA borg**.

- Documentation: [ha-borg/DOCS.md](ha-borg/DOCS.md)
- Example automation: [ha/automation-borg-backup.yaml](ha/automation-borg-backup.yaml)
- Tests: `tests/run-tests.sh` (needs docker)

## License

[MIT](LICENSE)

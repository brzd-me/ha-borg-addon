#!/usr/bin/env bats
# End-to-end runs of run.sh with curl/borg stubs (busybox sh, like the add-on).

setup() {
  export PATH="$PWD/tests/stubs:$PATH"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub" STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export DATA_DIR="$BATS_TEST_TMPDIR/data" TMP_DIR="$BATS_TEST_TMPDIR/tmp"
  export SUPERVISOR_URL=http://supervisor SUPERVISOR_TOKEN=t0ken
  export NOW_EPOCH=$(date -u -d "2026-10-13 08:00:00" +%s)
  mkdir -p "$STUB_DIR" "$DATA_DIR"; : > "$STUB_LOG"
  jq '{result: "ok", data: {backups: .}}' tests/fixtures/backups.json > "$STUB_DIR/GET_backups"
  write_options '{}'
}

# write_options <json overrides>: options.json = add-on defaults + overrides
write_options() {
  jq -n --argjson o "$1" '{borg_repo: "ssh://u@h/repo", borg_passphrase: "secret", borg_compression: "lz4",
    backup_prefix: "borg", archive_prefix: "ha", keep_local: 2, max_age_hours: 6,
    sensor_entity: "sensor.ha_borg_last_backup", sensor_name: "HA borg: last backup", stall_timeout_seconds: 300} + $o' > "$DATA_DIR/options.json"
}

creates() { grep -c " create " "$STUB_LOG" || true; }
deletes() { grep -c "^DELETE " "$STUB_LOG" || true; }
sensor() { jq -r "$1" "$STUB_LOG.body"; }

@test "happy path: all four sent oldest first, two oldest deleted, ok" {
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(grep " create " "$STUB_LOG" | sed 's/.*::\([^ ]*\).*/\1/' | tr '\n' ' ')" = \
    "ha-2026-10-10T02:30-b0000001 ha-2026-10-11T02:30-b0000002 ha-2026-10-12T02:30-b0000003 ha-2026-10-13T02:30-b0000004 " ]
  [ "$(jq -c 'sort' "$DATA_DIR/sent.json")" = '["b0000001","b0000002","b0000003","b0000004"]' ]
  grep -qx "DELETE /backups/b0000001 auth=bearer" "$STUB_LOG"
  grep -qx "DELETE /backups/b0000002 auth=bearer" "$STUB_LOG"
  [ "$(deletes)" -eq 2 ]
  [ "$(grep -m1 '^POST' "$STUB_LOG")" = "POST /core/api/states/sensor.ha_borg_last_backup auth=bearer" ]
  [ "$(sensor .state)" = ok ]
  [ "$(sensor '.attributes.added_mb')" = 40 ]
  [ "$(sensor '.attributes.sent | length')" = 4 ]
  [ "$(sensor '.attributes.error')" = "" ]
  [ "$(sensor '.attributes.last_run')" = "2026-10-13T08:00:00Z" ]
}

@test "second run sends nothing" {
  sh ha-borg/run.sh
  : > "$STUB_LOG"
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [ "$(sensor .state)" = ok ]
}

@test "borg failure on the 2nd backup: only the 1st recorded, nothing deleted, error" {
  BORG_STUB_FAIL_ON=b0000002 run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 2 ]
  [ "$(jq -c . "$DATA_DIR/sent.json")" = '["b0000001"]' ]
  [ "$(deletes)" -eq 0 ]
  [ "$(sensor .state)" = error ]
  [[ "$(sensor .attributes.error)" == *"Connection closed"* ]]
}

@test "download failure stops before borg" {
  echo 22 > "$STUB_DIR/GET_backups_b0000001_download.rc"
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
  [ "$(deletes)" -eq 0 ]
  [ "$(sensor .state)" = error ]
  [[ "$(sensor .attributes.error)" == *b0000001* ]]
}

@test "stale: unsent still sent, error about missing fresh backup" {
  export NOW_EPOCH=$(date -u -d "2026-10-14 12:00:00" +%s)
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 4 ]
  [ "$(sensor .state)" = error ]
  [[ "$(sensor .attributes.error)" == *"no fresh backup with prefix 'borg' within 6 h"* ]]
}

@test "archive already exists counts as sent" {
  BORG_STUB_MODE=exists run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(jq length "$DATA_DIR/sent.json")" -eq 4 ]
  [ "$(sensor .state)" = ok ]
}

@test "corrupt sent.json: nothing sent or deleted, error" {
  echo '{oops' > "$DATA_DIR/sent.json"
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
  [ "$(deletes)" -eq 0 ]
  [ "$(sensor .state)" = error ]
  [[ "$(sensor .attributes.error)" == *sent.json* ]]
}

@test "delete failure: ok with warning" {
  echo 22 > "$STUB_DIR/DELETE_backups_b0000001.rc"
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(sensor .state)" = ok ]
  [[ "$(sensor .attributes.warning)" == *"failed to delete b0000001"* ]]
}

@test "empty borg_repo: error, borg never called" {
  write_options '{"borg_repo": ""}'
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
  [ "$(sensor .state)" = error ]
  [ "$(sensor .attributes.error)" = "borg_repo is not set" ]
}

@test "sensor_name option becomes friendly_name" {
  write_options '{"sensor_name": "My sensor"}'
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(sensor .attributes.friendly_name)" = "My sensor" ]
}

@test "empty passphrase: error, borg never called" {
  write_options '{"borg_passphrase": ""}'
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
  [ "$(sensor .state)" = error ]
}

@test "missing options.json: exit 1, borg never called" {
  rm "$DATA_DIR/options.json"
  run sh ha-borg/run.sh
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
}

@test "temporary files are removed" {
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMP_DIR" 2>/dev/null)" ]
}

@test "options drive keep_local, archive prefix and sensor entity" {
  write_options '{"keep_local": 1, "archive_prefix": "test", "sensor_entity": "sensor.other", "stall_timeout_seconds": 120}'
  run sh ha-borg/run.sh
  [ "$status" -eq 0 ]
  [ "$(deletes)" -eq 3 ]
  [ "$(grep " create " "$STUB_LOG" | grep -c '::test-')" -eq 4 ]
  grep -q "^POST /core/api/states/sensor.other " "$STUB_LOG"
  ! grep -q "sensor.ha_borg_last_backup" "$STUB_LOG"
  grep -q -- "--speed-time 120" "$STUB_LOG.args"
}

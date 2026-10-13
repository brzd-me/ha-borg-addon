#!/usr/bin/env bats

setup() {
  . ha-borg/lib.sh
  export PATH="$PWD/tests/stubs:$PATH"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub" STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUB_DIR"; : > "$STUB_LOG"
  export SUPERVISOR_URL=http://supervisor SUPERVISOR_TOKEN=t0ken SENSOR_ENTITY=sensor.ha_borg_last_backup SENSOR_NAME="Test sensor" STALL_TIMEOUT=300
}

@test "sv_list_backups: returns .data.backups" {
  jq '{result: "ok", data: {backups: .}}' tests/fixtures/backups.json > "$STUB_DIR/GET_backups"
  run sv_list_backups
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq length)" -eq 6 ]
  grep -qx "GET /backups auth=bearer" "$STUB_LOG"
}

@test "sv_list_backups: result error -> non-zero" {
  echo '{"result":"error","message":"nope"}' > "$STUB_DIR/GET_backups"
  run sv_list_backups
  [ "$status" -ne 0 ]
  grep -qx "GET /backups auth=bearer" "$STUB_LOG"
}

@test "sv_list_backups: HTTP failure -> non-zero" {
  echo 22 > "$STUB_DIR/GET_backups.rc"
  run sv_list_backups
  [ "$status" -ne 0 ]
  grep -qx "GET /backups auth=bearer" "$STUB_LOG"
}

@test "sv_download: writes the backup to the file" {
  echo tardata > "$STUB_DIR/GET_backups_abc_download"
  run sv_download abc "$BATS_TEST_TMPDIR/abc.tar"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/abc.tar")" = tardata ]
  grep -qx "GET /backups/abc/download auth=bearer" "$STUB_LOG"
}

@test "sv_download: failure -> non-zero and no partial file" {
  echo 22 > "$STUB_DIR/GET_backups_abc_download.rc"
  run sv_download abc "$BATS_TEST_TMPDIR/abc.tar"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/abc.tar" ]
  grep -qx "GET /backups/abc/download auth=bearer" "$STUB_LOG"
}

@test "sv_delete: DELETE /backups/<slug>" {
  run sv_delete abc
  [ "$status" -eq 0 ]
  grep -qx "DELETE /backups/abc auth=bearer" "$STUB_LOG"
}

@test "sv_delete: failure -> non-zero" {
  echo 22 > "$STUB_DIR/DELETE_backups_abc.rc"
  run sv_delete abc
  [ "$status" -ne 0 ]
  grep -qx "DELETE /backups/abc auth=bearer" "$STUB_LOG"
}

@test "set_sensor: POST to the configured entity with state and attributes" {
  SENSOR_ENTITY=sensor.test_x run set_sensor ok '{"sent":[]}'
  [ "$status" -eq 0 ]
  grep -qx "POST /core/api/states/sensor.test_x auth=bearer" "$STUB_LOG"
  [ "$(jq -r .state "$STUB_LOG.body")" = ok ]
  [ "$(jq -c .attributes.sent "$STUB_LOG.body")" = '[]' ]
  [ "$(jq -r .attributes.friendly_name "$STUB_LOG.body")" = "Test sensor" ]
}

@test "set_sensor: curl failure is not fatal" {
  echo 7 > "$STUB_DIR/POST_core_api_states_sensor.ha_borg_last_backup.rc"
  run set_sensor error '{}'
  [ "$status" -eq 0 ]
}

@test "Supervisor requests give up after STALL_TIMEOUT without progress" {
  STALL_TIMEOUT=120 run sv_download abc "$BATS_TEST_TMPDIR/abc.tar"
  grep -q -- "--speed-limit 1024 --speed-time 120" "$STUB_LOG.args"
  grep -q -- "--connect-timeout 30" "$STUB_LOG.args"
}

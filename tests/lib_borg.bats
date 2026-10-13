#!/usr/bin/env bats

setup() {
  . ha-borg/lib.sh
  export PATH="$PWD/tests/stubs:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log" DATA_DIR="$BATS_TEST_TMPDIR/data"
  : > "$STUB_LOG"; mkdir -p "$DATA_DIR"
  export BORG_REPO=ssh://u@h/repo BORG_PASSPHRASE=p BORG_COMPRESSION=lz4 STALL_TIMEOUT=300
}

@test "ensure_ssh_key: creates an ed25519 key once and prints the public key" {
  run ensure_ssh_key
  [ "$status" -eq 0 ]
  [ -f "$DATA_DIR/ssh/id_ed25519" ]
  [[ "$output" == "Public key for the borg server: ssh-ed25519 "*" ha-borg" ]]
  before=$(cat "$DATA_DIR/ssh/id_ed25519")
  run ensure_ssh_key
  [ "$status" -eq 0 ]
  [ "$(cat "$DATA_DIR/ssh/id_ed25519")" = "$before" ]
  [[ "$output" == "Public key for the borg server: ssh-ed25519 "* ]]
}

@test "borg_env: ssh with the add-on key and known_hosts, base dir in DATA_DIR" {
  borg_env
  [ "$BORG_RSH" = "ssh -i $DATA_DIR/ssh/id_ed25519 -o UserKnownHostsFile=$DATA_DIR/ssh/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=10" ]
  [ "$BORG_BASE_DIR" = "$DATA_DIR/borg" ]
}

@test "borg_send: ok -> deduplicated bytes, create from the given dir" {
  mkdir -p "$BATS_TEST_TMPDIR/tmp"
  BORG_COMPRESSION=zstd,3 run borg_send "$BATS_TEST_TMPDIR/tmp" abc.tar ha-2026-10-13T02:30-abc
  [ "$status" -eq 0 ]
  [ "$output" = 10485760 ]
  grep -qx "cwd=$BATS_TEST_TMPDIR/tmp create --json --compression zstd,3 ::ha-2026-10-13T02:30-abc abc.tar" "$STUB_LOG"
}

@test "borg_send: archive already exists -> success with 0 bytes" {
  BORG_STUB_MODE=exists run borg_send "$BATS_TEST_TMPDIR" abc.tar ha-x-abc
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  grep -q "create" "$STUB_LOG"
}

@test "borg_send: other borg error -> non-zero with borg's message" {
  BORG_STUB_MODE=fail run borg_send "$BATS_TEST_TMPDIR" abc.tar ha-x-abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Connection closed by remote host"* ]]
  grep -q "create" "$STUB_LOG"
}

@test "borg_env: dead connection detected within STALL_TIMEOUT" {
  STALL_TIMEOUT=120 borg_env
  [[ "$BORG_RSH" == *"-o ServerAliveInterval=30 -o ServerAliveCountMax=4"* ]]
}

@test "borg_send: some other 'already exists' error is a failure" {
  BORG_STUB_MODE=other_exists run borg_send "$BATS_TEST_TMPDIR" abc.tar ha-x-abc
  [ "$status" -ne 0 ]
  grep -q "create" "$STUB_LOG"
}

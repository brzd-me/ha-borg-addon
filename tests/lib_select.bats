#!/usr/bin/env bats

setup() {
  . ha-borg/lib.sh
  B=$(cat tests/fixtures/backups.json)
}

# 10 unsent "borg" backups, 2026-10-01 .. 2026-10-10, listed newest first
ten_backups() {
  jq -n '[range(10;0;-1) | {slug: "t\(.)", name: "borg x", date: "2026-10-\(if . < 10 then "0\(.)" else "\(.)" end)T02:30:00+00:00"}]'
}

@test "select_pending: nothing sent -> all prefixed, oldest first" {
  run select_pending "$B" '[]' borg
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'b0000001\nb0000002\nb0000003\nb0000004')" ]
}

@test "select_pending: two oldest sent -> two newest" {
  run select_pending "$B" '["b0000001","b0000002"]' borg
  [ "$output" = "$(printf 'b0000003\nb0000004')" ]
}

@test "select_pending: never manual or pre-update backups" {
  run select_pending "$B" '[]' borg
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != *m0000001* ]]
  [[ "$output" != *c0000001* ]]
}

@test "select_pending: 10 unsent -> all 10 in date order" {
  run select_pending "$(ten_backups)" '[]' borg
  [ "$output" = "$(printf 't%s\n' 1 2 3 4 5 6 7 8 9 10 | sed '$!b')" ]
}

@test "select_to_delete: keep=2, all sent -> two oldest" {
  run select_to_delete "$B" '["b0000001","b0000002","b0000003","b0000004"]' borg 2
  [ "$output" = "$(printf 'b0000001\nb0000002')" ]
}

@test "select_to_delete: oldest not sent -> only the second" {
  run select_to_delete "$B" '["b0000002","b0000003","b0000004"]' borg 2
  [ "$output" = "b0000002" ]
}

@test "select_to_delete: never manual or pre-update backups" {
  run select_to_delete "$B" '["b0000001","b0000002","b0000003","b0000004","m0000001","c0000001"]' borg 0
  [[ "$output" != *m0000001* ]]
  [[ "$output" != *c0000001* ]]
  [ "$(echo "$output" | wc -l)" -eq 4 ]
}

@test "select_to_delete: keep=2 and 10 unsent -> nothing" {
  run select_to_delete "$(ten_backups)" '[]' borg 2
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "newest_age_hours: newest borg backup 13.10 02:30, now 08:30 -> 6" {
  now=$(iso_to_epoch 2026-10-13T08:30:00Z)
  run newest_age_hours "$B" borg "$now"
  [ "$output" = "6" ]
}

@test "newest_age_hours: no prefixed backups -> -1" {
  run newest_age_hours "$B" nosuch 1791858601
  [ "$output" = "-1" ]
}

@test "archive_name: prefix, minute precision, slug" {
  run archive_name ha 2026-10-13T02:30:01.123456+00:00 abcd1234
  [ "$output" = "ha-2026-10-13T02:30-abcd1234" ]
}

@test "iso_to_epoch: fraction and offset dropped" {
  [ "$(iso_to_epoch 2026-10-13T02:30:01.123456+00:00)" = "1791858601" ]
  [ "$(iso_to_epoch 2026-10-13T02:30:01Z)" = "1791858601" ]
}

@test "backup_date: date field of slug" {
  run backup_date "$B" b0000003
  [ "$output" = "2026-10-12T02:30:01.123456+00:00" ]
}

@test "prune_sent: drops slugs no longer in HA" {
  run prune_sent '["b0000001","gone"]' "$B"
  [ "$(echo "$output" | jq -c .)" = '["b0000001"]' ]
}

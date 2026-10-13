#!/bin/sh
# ha-borg helpers. Sourced by run.sh and by the tests.
# <backups_json> everywhere is the .data.backups array of Supervisor GET /backups.

# --- pure selection helpers (JSON in arguments, result on stdout) ---

# iso_to_epoch <date_iso>: UTC seconds; fraction and offset (+00:00 / Z) are dropped.
iso_to_epoch() {
    date -u -d "$(printf '%s' "$1" | cut -c1-19 | tr T ' ')" +%s
}

# select_pending <backups_json> <sent_json> <prefix>: unsent prefixed slugs, oldest first.
select_pending() {
    printf '%s' "$1" | jq -r --argjson sent "$2" --arg p "$3" \
        '[.[] | select((.name | startswith($p)) and ((.slug | IN($sent[])) | not))]
         | sort_by(.date) | .[].slug'
}

# select_to_delete <backups_json> <sent_json> <prefix> <keep>:
# sent prefixed slugs that are not among the <keep> newest prefixed backups.
select_to_delete() {
    printf '%s' "$1" | jq -r --argjson sent "$2" --arg p "$3" --argjson keep "$4" \
        '[.[] | select(.name | startswith($p))] | sort_by(.date) | reverse | .[$keep:]
         | map(select(.slug | IN($sent[]))) | reverse | .[].slug'
}

# newest_age_hours <backups_json> <prefix> <now_epoch>: whole hours since the newest
# prefixed backup, -1 when there is none.
newest_age_hours() {
    _newest=$(printf '%s' "$1" | jq -r --arg p "$2" \
        '[.[] | select(.name | startswith($p))] | sort_by(.date) | last | .date // empty')
    if [ -z "$_newest" ]; then echo -1; return; fi
    echo $(( ($3 - $(iso_to_epoch "$_newest")) / 3600 ))
}

# archive_name <archive_prefix> <date_iso> <slug> -> ha-2026-10-13T02:30-abcd1234
archive_name() {
    echo "$1-$(printf '%s' "$2" | cut -c1-16)-$3"
}

# backup_date <backups_json> <slug>
backup_date() {
    printf '%s' "$1" | jq -r --arg s "$2" '.[] | select(.slug == $s) | .date'
}

# prune_sent <sent_json> <backups_json>: sent slugs that still exist in HA.
prune_sent() {
    printf '%s' "$1" | jq -c --argjson b "$2" '[.[] | select(IN($b[].slug))]'
}

# --- Supervisor / Home Assistant API (env: SUPERVISOR_URL, SUPERVISOR_TOKEN, SENSOR_ENTITY, SENSOR_NAME, STALL_TIMEOUT) ---

_sv() {
    # give up when nothing moves for STALL_TIMEOUT seconds instead of hanging forever
    curl -fsS --connect-timeout 30 --speed-limit 1024 --speed-time "$STALL_TIMEOUT" \
        -H "Authorization: Bearer $SUPERVISOR_TOKEN" "$@"
}

# sv_list_backups: stdout .data.backups; non-zero on HTTP error or result != ok.
sv_list_backups() {
    _resp=$(_sv "$SUPERVISOR_URL/backups") || return 1
    printf '%s' "$_resp" | jq -ce 'select(.result == "ok") | .data.backups'
}

# sv_download <slug> <dest_file>: no partial file is left on failure.
sv_download() {
    _sv -o "$2" "$SUPERVISOR_URL/backups/$1/download" && return 0
    rm -f "$2"
    return 1
}

# sv_delete <slug>
sv_delete() {
    _sv -X DELETE "$SUPERVISOR_URL/backups/$1" >/dev/null
}

# set_sensor <state> <attrs_json>: never fails, the sensor must not break a backup run.
set_sensor() {
    _body=$(jq -cn --arg s "$1" --argjson a "$2" --arg n "$SENSOR_NAME" \
        '{state: $s, attributes: ($a + {friendly_name: $n})}')
    _sv -X POST -H "Content-Type: application/json" -d "$_body" \
        "$SUPERVISOR_URL/core/api/states/$SENSOR_ENTITY" >/dev/null \
        || echo "warning: failed to update $SENSOR_ENTITY" >&2
    return 0
}

# --- borg and ssh (env: DATA_DIR, BORG_REPO, BORG_PASSPHRASE, BORG_COMPRESSION, STALL_TIMEOUT) ---

# ensure_ssh_key: create the add-on's own key on first run; always print the public key
# (it has to be added to authorized_keys on the borg server).
ensure_ssh_key() {
    mkdir -p "$DATA_DIR/ssh" && chmod 700 "$DATA_DIR/ssh"
    if [ ! -f "$DATA_DIR/ssh/id_ed25519" ]; then
        ssh-keygen -q -t ed25519 -N "" -C ha-borg -f "$DATA_DIR/ssh/id_ed25519" || return 1
    fi
    echo "Public key for the borg server: $(cat "$DATA_DIR/ssh/id_ed25519.pub")"
}

borg_env() {
    # keepalives drop a dead connection after ~STALL_TIMEOUT seconds
    export BORG_RSH="ssh -i $DATA_DIR/ssh/id_ed25519 -o UserKnownHostsFile=$DATA_DIR/ssh/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=$(( (STALL_TIMEOUT + 29) / 30 ))"
    export BORG_BASE_DIR="$DATA_DIR/borg"
}

# borg_send <dir> <file> <archive>: stdout deduplicated bytes (0 if the archive already
# exists: an earlier run sent it but did not record it). Other borg errors -> stderr, non-zero.
borg_send() {
    _err=$(mktemp)
    _out=$(cd "$1" && borg create --json --compression "$BORG_COMPRESSION" "::$3" "$2" 2>"$_err")
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        printf '%s' "$_out" | jq -r '.archive.stats.deduplicated_size'
    elif grep -qxF "Archive $3 already exists" "$_err"; then
        echo 0; _rc=0
    else
        cat "$_err" >&2
    fi
    rm -f "$_err"
    return "$_rc"
}

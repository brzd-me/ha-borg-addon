#!/bin/sh
# ha-borg: send unsent HA backups (name starts with backup_prefix) to borg once each,
# delete old local ones, report the result in a sensor. Exit 0 = ok, 1 = error.
. "$(dirname "$0")/lib.sh"

DATA_DIR=${DATA_DIR:-/data}
OPTIONS_FILE=${OPTIONS_FILE:-$DATA_DIR/options.json}
TMP_DIR=${TMP_DIR:-/tmp/ha-borg}
SUPERVISOR_URL=${SUPERVISOR_URL:-http://supervisor}
NOW_EPOCH=${NOW_EPOCH:-$(date +%s)}
SENT_FILE="$DATA_DIR/sent.json"
export DATA_DIR SUPERVISOR_URL

opt() { jq -r ".$1" "$OPTIONS_FILE"; }

if ! jq -e 'type == "object"' "$OPTIONS_FILE" >/dev/null 2>&1; then
    echo "error: cannot read options from $OPTIONS_FILE" >&2
    exit 1
fi
export BORG_REPO=$(opt borg_repo) BORG_PASSPHRASE=$(opt borg_passphrase)
export BORG_COMPRESSION=$(opt borg_compression) SENSOR_ENTITY=$(opt sensor_entity)
export SENSOR_NAME=$(opt sensor_name)
BACKUP_PREFIX=$(opt backup_prefix)
ARCHIVE_PREFIX=$(opt archive_prefix)
KEEP_LOCAL=$(opt keep_local)
MAX_AGE_HOURS=$(opt max_age_hours)
export STALL_TIMEOUT=$(opt stall_timeout_seconds)

ERRORS=""; WARNINGS=""; SENT_ARCHIVES="[]"; ADDED_BYTES=0; FINISHED=0
add_error() { echo "error: $1" >&2; ERRORS="${ERRORS:+$ERRORS; }$1"; }
add_warning() { echo "warning: $1" >&2; WARNINGS="${WARNINGS:+$WARNINGS; }$1"; }

on_exit() {
    rm -rf "$TMP_DIR"
    [ "$FINISHED" = 1 ] || set_sensor error '{"error": "unexpected failure, see add-on log"}'
}
trap on_exit EXIT
trap 'exit 1' INT TERM

finish() {
    if [ -n "$ERRORS" ]; then state=error; rc=1; else state=ok; rc=0; fi
    attrs=$(jq -cn --arg last "$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson sent "$SENT_ARCHIVES" --arg bytes "$ADDED_BYTES" \
        --arg error "$ERRORS" --arg warning "$WARNINGS" \
        '{last_run: $last, sent: $sent, added_mb: (($bytes | tonumber) / 1048576 * 10 | round / 10),
          error: $error, warning: $warning}')
    set_sensor "$state" "$attrs"
    echo "result: $state, sent $(printf '%s' "$SENT_ARCHIVES" | jq length) archive(s)${ERRORS:+, errors: $ERRORS}${WARNINGS:+, warnings: $WARNINGS}"
    FINISHED=1
    exit "$rc"
}

set_sensor running '{}'

[ -n "$BORG_REPO" ] || { add_error "borg_repo is not set"; finish; }
[ -n "$BORG_PASSPHRASE" ] || { add_error "borg_passphrase is not set"; finish; }

if [ -f "$SENT_FILE" ]; then
    SENT=$(jq -ce 'select(type == "array" and all(.[]; type == "string"))' "$SENT_FILE" 2>/dev/null) \
        || { add_error "$SENT_FILE is corrupt, fix or delete it (deleting re-sends all '$BACKUP_PREFIX' backups)"; finish; }
else
    SENT="[]"
fi

ensure_ssh_key || { add_error "cannot create ssh key"; finish; }
borg_env

BACKUPS=$(sv_list_backups) || { add_error "cannot list backups from Supervisor"; finish; }

mark_sent() {
    SENT=$(printf '%s' "$SENT" | jq -c --arg s "$1" '. + [$s]')
    printf '%s\n' "$SENT" > "$SENT_FILE.tmp" && mv "$SENT_FILE.tmp" "$SENT_FILE"
}

SEND_FAILED=0
mkdir -p "$TMP_DIR"
for slug in $(select_pending "$BACKUPS" "$SENT" "$BACKUP_PREFIX"); do
    archive=$(archive_name "$ARCHIVE_PREFIX" "$(backup_date "$BACKUPS" "$slug")" "$slug")
    echo "sending $slug as $archive"
    if ! sv_download "$slug" "$TMP_DIR/$slug.tar"; then
        add_error "cannot download backup $slug"; SEND_FAILED=1; break
    fi
    if ! bytes=$(borg_send "$TMP_DIR" "$slug.tar" "$archive" 2>"$TMP_DIR/borg.err"); then
        cat "$TMP_DIR/borg.err" >&2
        add_error "borg failed for $slug: $(tail -n 1 "$TMP_DIR/borg.err")"; SEND_FAILED=1; break
    fi
    rm -f "$TMP_DIR/$slug.tar"
    mark_sent "$slug"
    SENT_ARCHIVES=$(printf '%s' "$SENT_ARCHIVES" | jq -c --arg a "$archive" '. + [$a]')
    ADDED_BYTES=$((ADDED_BYTES + bytes))
    echo "sent, +$(( bytes / 1048576 )) MB"
done

age=$(newest_age_hours "$BACKUPS" "$BACKUP_PREFIX" "$NOW_EPOCH")
if [ "$age" -lt 0 ] || [ "$age" -gt "$MAX_AGE_HOURS" ]; then
    add_error "no fresh backup with prefix '$BACKUP_PREFIX' within $MAX_AGE_HOURS h"
fi

if [ "$SEND_FAILED" = 0 ]; then
    for slug in $(select_to_delete "$BACKUPS" "$SENT" "$BACKUP_PREFIX" "$KEEP_LOCAL"); do
        if sv_delete "$slug"; then echo "deleted $slug"; else add_warning "failed to delete $slug"; fi
    done
    SENT=$(prune_sent "$SENT" "$BACKUPS")
    printf '%s\n' "$SENT" > "$SENT_FILE.tmp" && mv "$SENT_FILE.tmp" "$SENT_FILE"
fi

finish

#!/bin/sh
# Nightly backup to the restic repository on B2: the miniflux and authelia
# dumps written by the `dump` init containers to /dump, slskd's state at
# /data/slskd and lldap's SQLite database at /data/lldap (copied live: lldap
# rarely writes).
# restic encrypts with RESTIC_PASSWORD before anything leaves the node.
# Any failure is sent to Telegram and fails the Job.
set -u

fail() {
	echo "FAILED: $1" >&2
	wget -q -O /dev/null --header 'Content-Type: application/json' \
		--post-data "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Backup failed: $1. kubectl -n backup logs -l app.kubernetes.io/name=restic --tail=50\"}" \
		"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
		|| echo "Telegram notification failed too" >&2
	exit 1
}

# Snapshots are grouped by host for retention: a fixed name, not the pod's.
host=cluster

# The first run creates the repository.
restic cat config >/dev/null 2>&1 || restic init || fail "restic init"

# slskd's downloads/ and incomplete/ are transfers, not state.
restic backup --host "$host" \
	--exclude /data/slskd/downloads --exclude /data/slskd/incomplete \
	/dump /data/slskd /data/lldap || fail "restic backup"
restic forget --host "$host" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune \
	|| fail "restic forget"

# The dump steps never fail the pod, so the files are backed up either way.
[ -s /dump/miniflux.dump ] || fail "pg_dump miniflux (the rest was backed up)"
[ -s /dump/authelia.dump ] || fail "pg_dump authelia (the rest was backed up)"
echo "Backup finished"

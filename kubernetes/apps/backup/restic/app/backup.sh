#!/bin/sh
# Nightly backup to the restic repository on B2: the miniflux dump written by
# the `dump` init container to /dump, and slskd's state at /data/slskd.
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

restic backup --host "$host" /dump /data/slskd || fail "restic backup"
restic forget --host "$host" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune \
	|| fail "restic forget"

# The dump step never fails the pod, so slskd is backed up either way.
[ -s /dump/miniflux.dump ] || fail "pg_dump (slskd was backed up)"
echo "Backup finished"

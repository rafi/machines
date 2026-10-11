# Library of i/o tasks to be included in apps/*/justfile
# Copyright (c) 2024 Rafael Bodill.
#
# Tasks should be short and sweet, and not contain application logic.

[private]
list:
	@just --list --unsorted

[private]
with-binary host *vars:
	cat ../../lib/functions.sh installer.sh | ssh {{ host }} '{{ vars }}' sh -s

[private]
with-package-manager host: (with-binary host 'USE_PACKAGE_MANAGER=1')

[private]
rsync host host-dir *extra-src-files:
	rsync -hlrtWxz --ignore-missing-args --progress \
		files/ {{ extra-src-files }} {{ host }}:{{ host-dir }}

[private]
sync-files host *extra: (rsync host '/tmp/' + APP_NAME invocation_dir() + '/.env' extra)

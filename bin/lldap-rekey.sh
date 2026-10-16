#!/usr/bin/env bash
# Replace lldap's key_seed in the cluster. With lldap scaled down, a one-off
# pod runs lldap on its data (/opt/lldap, after a copy of users.db there) with
# the new seed and the force flags: it re-keys, resets the admin password from
# lldap-env, and exits. Then the seed goes to pass, `just kube secrets lldap`
# applies it, and lldap starts again. The seed reaches the cluster through a
# temporary Secret, never a command line. Users not in the bootstrap Secret
# must set new passwords.
set -euo pipefail

root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
read -rp 'Re-key lldap? Users outside the bootstrap Secret must set new passwords. [y/N] ' answer
[[ $answer == [yY] ]] || exit 1

hr=$root/kubernetes/apps/auth/lldap/app/helmrelease.yaml
image="$(yq '.spec.values.controllers.lldap.containers.app.image | .repository + ":" + .tag' "$hr")"
seed="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 40)"
k() { kubectl -n auth "$@"; }

# On any failure lldap comes back with its current seed.
trap 'k delete pod/lldap-rekey secret/lldap-rekey --ignore-not-found >/dev/null; k scale deploy/lldap --replicas=1 >/dev/null' EXIT
printf 'LLDAP_KEY_SEED=%s\nLLDAP_FORCE_UPDATE_PRIVATE_KEY=true\nLLDAP_FORCE_LDAP_USER_PASS_RESET=true\n' "$seed" \
	| k create secret generic lldap-rekey --from-env-file=/dev/stdin >/dev/null
k scale deploy/lldap --replicas=0
while [[ -n "$(k get pods -l app.kubernetes.io/name=lldap,app.kubernetes.io/controller=lldap -o name)" ]]; do sleep 2; done
k apply -f - <<-EOF
	apiVersion: v1
	kind: Pod
	metadata:
	  name: lldap-rekey
	spec:
	  restartPolicy: Never
	  containers:
	    - name: lldap
	      image: $image
	      command: [sh, -c, 'cp -a /data/users.db "/data/users.db-\$(date +%Y%m%d%H%M%S)-rekey" && exec /docker-entrypoint.sh run --config-file /data/lldap_config.toml']
	      env:
	        - { name: LLDAP_DATABASE_URL, value: "sqlite:///data/users.db?mode=rwc" }
	      # The later source wins: lldap-rekey's seed over lldap-env's.
	      envFrom:
	        - secretRef: { name: lldap-env }
	        - secretRef: { name: lldap-rekey }
	      volumeMounts:
	        - { name: data, mountPath: /data }
	  volumes:
	    - name: data
	      hostPath: { path: /opt/lldap, type: Directory }
EOF
until phase="$(k get pod lldap-rekey -o jsonpath='{.status.phase}')" && [[ $phase == Succeeded || $phase == Failed ]]; do sleep 2; done
out="$(k logs lldap-rekey)"
printf '%s\n' "$out" | grep -iE 'private key|admin password|error|restart' || true
# lldap exits with this message once the key and admin password are updated.
grep -q 'Restart the server without' <<< "$out"
printf '%s' "$seed" | pass insert -m -f secretspec/machines/default/LLDAP_KEY_SEED >/dev/null
echo "LLDAP_KEY_SEED updated in pass"
just -f "$root/justfile" kube secrets lldap

#!/usr/bin/env bash
# Linux only: foreground Oracle session; no VM and no auto-start service.
set -euo pipefail

bind_ip=${1:-127.0.0.1}
container_name=plcraft-db
image=container-registry.oracle.com/database/free:latest
runner_pid=

command -v podman >/dev/null
if podman container exists "$container_name"; then
  echo "Container $container_name already exists. Inspect it with podman ps -a." >&2
  exit 1
fi

read -r -s -p 'Oracle administrator password (use the same on later starts): ' ORACLE_PWD
printf '\n'
if [[ -z "$ORACLE_PWD" ]]; then
  echo 'A password is required.' >&2
  exit 1
fi
export ORACLE_PWD
session_dir=$(mktemp -d)

cleanup() {
  trap - EXIT HUP INT TERM
  unset ORACLE_PWD
  if [[ -s "$session_dir/container.cid" ]]; then
    local container_id=''
    IFS= read -r container_id < "$session_dir/container.cid" || true
    printf '\nStopping Oracle; please wait...\n'
    podman stop --time 60 "$container_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$runner_pid" ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  rm -rf -- "$session_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Oracle will listen on $bind_ip:1521. Keep this terminal open. Ctrl-C stops it."
podman run --rm --name "$container_name" \
  --cidfile "$session_dir/container.cid" \
  --restart=no --stop-timeout=60 --shm-size=1g --pull=never \
  --publish "$bind_ip:1521:1521" \
  --env ORACLE_PWD \
  --volume plcraft-data:/opt/oracle/oradata \
  "$image" &
runner_pid=$!
unset ORACLE_PWD
wait "$runner_pid"

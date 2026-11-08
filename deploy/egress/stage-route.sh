#!/bin/sh
# Add one /32 route inside the stage client's own network namespace.
# The namespace is the Docker netns file for that container, opened and held
# as a file descriptor. Entry uses that descriptor only. A process id is never
# a namespace argument: the pid can exit and be reused.
# This script does not change the host routing table, sysctls, or capabilities.
set -eu

dest=""
via=""
container=""
project=""
service=""
docker="docker"
proc_root="/proc"
host_ns=""
fixture_prefix=""
allow_fixture=0
fd_open=0

die() {
  echo "stage-route: $*" >&2
  if [ "$fd_open" -eq 1 ]; then
    exec 9<&-
    fd_open=0
  fi
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --docker) docker=${2:?}; shift 2 ;;
    --container) container=${2:?}; shift 2 ;;
    --project) project=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --dest) dest=${2:?}; shift 2 ;;
    --via) via=${2:?}; shift 2 ;;
    --proc-root) proc_root=${2:?}; shift 2 ;;
    --host-ns) host_ns=${2:?}; shift 2 ;;
    --allow-fixture-prefix) allow_fixture=1; fixture_prefix=${2:?}; shift 2 ;;
    *) die "unknown argument" ;;
  esac
done

command -v nsenter >/dev/null 2>&1 || die "nsenter is required"
command -v ip >/dev/null 2>&1 || die "ip is required"
command -v stat >/dev/null 2>&1 || die "stat is required"

ipv4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
printf '%s\n' "$dest" | grep -Eq "$ipv4" || die "destination is not an IPv4 address"
printf '%s\n' "$via" | grep -Eq "$ipv4" || die "gateway is not an IPv4 address"
printf '%s\n' "$container" | grep -Eq '^[0-9a-f]{64}$' || die "container id is not 64 hex characters"
printf '%s\n' "$project" | grep -Eq '^vvrst[0-9a-f]{6}$' || die "project is not a stage project"
[ "$service" = "client" ] || die "service is not the stage client"
[ -n "$host_ns" ] || host_ns="$proc_root/1/ns/net"

fmt='{{.Id}}{{"\t"}}{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{.State.Running}}{{"\t"}}{{.State.Pid}}{{"\t"}}{{.HostConfig.NetworkMode}}{{"\t"}}{{.HostConfig.PidMode}}{{"\t"}}{{.HostConfig.Privileged}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{.NetworkSettings.SandboxKey}}'

field() {
  printf '%s\n' "$1" | awk -F '\t' -v n="$2" '{ print $n }'
}

inspect_line() {
  "$docker" inspect --format "$fmt" "$1"
}

load_line() {
  line=$1
  nf=$(printf '%s\n' "$line" | awk -F '\t' '{ print NF; exit }')
  [ "$nf" -eq 11 ] || die "inspect record is malformed"
  got_id=$(field "$line" 1)
  got_name=$(field "$line" 2)
  got_status=$(field "$line" 3)
  got_running=$(field "$line" 4)
  got_pid=$(field "$line" 5)
  got_netmode=$(field "$line" 6)
  got_pidmode=$(field "$line" 7)
  got_priv=$(field "$line" 8)
  got_project=$(field "$line" 9)
  got_service=$(field "$line" 10)
  got_sandbox=$(field "$line" 11)
}

assert_identity() {
  [ "$got_id" = "$container" ] || die "inspect id does not match the stage client"
  [ "$got_running" = "true" ] || die "stage client is not running"
  [ "$got_status" = "running" ] || die "stage client status is $got_status"
  printf '%s\n' "$got_pid" | grep -Eq '^[0-9]+$' || die "stage client pid is malformed"
  [ "$got_pid" -gt 1 ] || die "stage client pid is not a container process"
  [ "$got_netmode" != "host" ] || die "stage client uses the host network"
  [ "$got_pidmode" != "host" ] || die "stage client uses the host pid namespace"
  [ "$got_priv" = "false" ] || die "stage client is privileged"
  [ "$got_project" = "$project" ] || die "compose project does not match"
  [ "$got_service" = "client" ] || die "compose service is not client"
  [ "$got_name" = "/$project-client-1" ] || die "container name does not match the stage client"
  [ -n "$got_sandbox" ] || die "sandbox path is empty"
  case "$got_sandbox" in
    *..*|*' '*|*'//'*) die "sandbox path is not a single netns name" ;;
  esac
  real_sandbox=$(readlink -f -- "$got_sandbox") || die "sandbox path does not resolve"
  base=${real_sandbox##*/}
  dir=${real_sandbox%/*}
  printf '%s\n' "$base" | grep -Eq '^[A-Za-z0-9]+$' || die "sandbox name is not a single token"
  if [ "$allow_fixture" -eq 1 ]; then
    case "$fixture_prefix" in
      /|/proc|/proc/*|/run|/run/*|/var/run|/var/run/*) die "fixture prefix is not isolated" ;;
    esac
    prefix_real=$(readlink -f -- "$fixture_prefix") || die "fixture prefix does not resolve"
    case "$real_sandbox" in
      "$prefix_real"/*) ;;
      *) die "sandbox escaped the fixture prefix" ;;
    esac
  else
    case "$dir" in
      /var/run/docker/netns|/run/docker/netns) ;;
      *) die "sandbox is not a docker netns file" ;;
    esac
  fi
  [ "$dir/$base" = "$real_sandbox" ] || die "sandbox is not a single path segment"
}

pid_matches() {
  pid_ns="$proc_root/$got_pid/ns/net"
  [ -e "$pid_ns" ] || die "stage client pid has no network namespace"
  pid_ino=$(stat -L -c '%d:%i' -- "$pid_ns") || die "cannot stat the pid namespace"
  [ "$pid_ino" = "$sandbox_ino" ] || die "pid namespace does not match the sandbox"
  cgroup="$proc_root/$got_pid/cgroup"
  [ -f "$cgroup" ] || die "stage client cgroup is missing"
  grep -F -q -- "$container" "$cgroup" || die "pid cgroup is not the stage client"
}

line=$(inspect_line "$container") || die "cannot inspect the stage client"
load_line "$line"
assert_identity
first_pid=$got_pid
first_sandbox=$real_sandbox
sandbox_ino=$(stat -L -c '%d:%i' -- "$real_sandbox") || die "cannot stat the sandbox"
host_ino=$(stat -L -c '%d:%i' -- "$host_ns") || die "cannot stat the host namespace"
self_ino=$(stat -L -c '%d:%i' -- /proc/self/ns/net) || die "cannot stat the caller namespace"
[ "$sandbox_ino" != "$host_ino" ] || die "sandbox is the host network namespace"
[ "$sandbox_ino" != "$self_ino" ] || die "sandbox is the caller's network namespace"
pid_matches

others=$("$docker" ps -aq) || die "cannot list containers"
for other in $others; do
  oline=$(inspect_line "$other") || die "cannot inspect $other"
  oid=$(field "$oline" 1)
  [ "$oid" = "$container" ] && continue
  osandbox=$(field "$oline" 11)
  [ -n "$osandbox" ] || continue
  [ -e "$osandbox" ] || die "another container has a sandbox path that cannot be stat"
  oino=$(stat -L -c '%d:%i' -- "$osandbox") || die "cannot stat another sandbox"
  [ "$oino" != "$sandbox_ino" ] || die "sandbox is shared with another container"
done

exec 9<"$real_sandbox" || die "cannot pin the sandbox"
fd_open=1
fd_ino=$(stat -L -c '%d:%i' -- /proc/self/fd/9) || die "cannot stat the pinned descriptor"
[ "$fd_ino" = "$sandbox_ino" ] || die "pinned descriptor is not the sandbox"

line=$(inspect_line "$container") || die "cannot reinspect the stage client"
load_line "$line"
assert_identity
[ "$got_pid" = "$first_pid" ] || die "stage client pid changed before entry"
[ "$real_sandbox" = "$first_sandbox" ] || die "sandbox path changed before entry"
sandbox_ino=$(stat -L -c '%d:%i' -- "$real_sandbox") || die "cannot stat the sandbox after pinning"
[ "$sandbox_ino" = "$fd_ino" ] || die "sandbox changed after it was pinned"
[ "$sandbox_ino" != "$host_ino" ] || die "pinned namespace is the host"
self_now=$(stat -L -c '%d:%i' -- /proc/self/ns/net) || die "cannot stat the caller namespace"
[ "$sandbox_ino" != "$self_now" ] || die "pinned namespace is the caller"
pid_matches

nsenter --net=/proc/self/fd/9 -- ip route replace "$dest/32" via "$via" || die "route was not added in the pinned namespace"
exec 9<&-
fd_open=0

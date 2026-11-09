#!/bin/sh
# Regression for stage-route.sh. Uses fixture files and stub commands.
# It does not create a host route or enter the host network namespace.
set -eu

root=${1:?}
helper=$root/stage-route.sh
work=$(mktemp -d)
keep=$work

fail() {
  echo "FAIL: $1" >&2
  echo "fixture left at $keep" >&2
  exit 1
}

client=$(awk 'BEGIN { while (length(s) < 64) s = s "a"; print s }')
other=$(awk 'BEGIN { while (length(s) < 64) s = s "b"; print s }')
project=vvrstabcdef
dest=172.30.144.10
via=172.30.143.2
pid=4242

tools=$work/tools
stubs=$work/stubs
mkdir -p "$tools" "$stubs" "$work/netns" "$work/proc/1/ns" "$work/proc/$pid/ns" "$work/proc/$pid"
for bin in stat readlink awk grep cat; do
  ln -s "$(command -v "$bin")" "$tools/$bin"
done

cat > "$stubs/nsenter" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_ROOT:?}/nsenter.log"
[ "$1" = "--net=/proc/self/fd/9" ] || exit 97
[ "$2" = "--" ] || exit 97
got=$(stat -L -c '%d:%i' /proc/self/fd/9)
want=$(cat "${STUB_ROOT}/expect.stat")
[ "$got" = "$want" ] || exit 98
shift 2
exec "$@"
EOF
cat > "$stubs/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_ROOT:?}/ip.log"
exit 0
EOF
cat > "$stubs/docker" <<'EOF'
#!/bin/sh
set -eu
root=${STUB_ROOT:?}
printf '%s\n' "$*" >> "$root/docker.log"
if [ "$1" = "ps" ]; then
  cat "$root/ps.ids"
  exit 0
fi
[ "$1" = "inspect" ] || exit 2
id=""
for arg in "$@"; do
  id=$arg
done
n=0
if [ -f "$root/count-$id" ]; then
  n=$(cat "$root/count-$id")
fi
n=$((n + 1))
printf '%s\n' "$n" > "$root/count-$id"
if [ -f "$root/inspect-$id-$n" ]; then
  cat "$root/inspect-$id-$n"
  exit 0
fi
if [ -f "$root/inspect-$id" ]; then
  cat "$root/inspect-$id"
  exit 0
fi
echo "missing inspect $id" >&2
exit 1
EOF
chmod 0755 "$stubs/nsenter" "$stubs/ip" "$stubs/docker"

printf '%s\n' 'host' > "$work/hostns"
printf '%s\n' 'client-ns' > "$work/netns/abc"
ln "$work/netns/abc" "$work/proc/$pid/ns/net"
printf '0::/docker/%s\n' "$client" > "$work/proc/$pid/cgroup"
printf '%s\n' 'other-ns' > "$work/netns/other"
: > "$work/ps.ids"
export STUB_ROOT=$work
stat -L -c '%d:%i' "$work/netns/abc" > "$work/expect.stat"

record() {
  id=$1
  name=$2
  status=$3
  running=$4
  cpid=$5
  netmode=$6
  pidmode=$7
  priv=$8
  proj=$9
  svc=${10}
  sandbox=${11}
  slot=${12:-}
  destf=$work/inspect-$id
  if [ -n "$slot" ]; then
    destf=$work/inspect-$id-$slot
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$name" "$status" "$running" "$cpid" "$netmode" "$pidmode" "$priv" "$proj" "$svc" "$sandbox" > "$destf"
}

base_record() {
  record "$client" "/$project-client-1" running true "$pid" bridge "" false "$project" client "$work/netns/abc" "$1"
}

expect_reject() {
  label=$1
  shift
  rm -f "$work"/count-*
  : > "$work/nsenter.log"
  : > "$work/ip.log"
  if PATH="$stubs:$tools" "$helper" "$@" >"$work/out" 2>"$work/err"; then
    fail "$label was accepted"
  fi
  if [ -s "$work/nsenter.log" ] || [ -s "$work/ip.log" ]; then
    fail "$label entered a namespace or ran ip"
  fi
}

base_record ""
record "$other" "/vvrstffffff-client-1" exited false 0 bridge "" false vvrstffffff client "$work/netns/other"
printf '%s\n' "$other" > "$work/ps.ids"

common() {
  printf '%s\n' \
    --docker "$stubs/docker" \
    --container "$client" \
    --project "$project" \
    --service client \
    --dest "$dest" \
    --via "$via" \
    --proc-root "$work/proc" \
    --host-ns "$work/hostns" \
    --allow-fixture-prefix "$work/netns"
}

# shellcheck disable=SC2046
set -- $(common)

if PATH="$tools" "$helper" "$@" >"$work/out" 2>"$work/err"; then
  fail "missing nsenter was accepted"
fi
grep -q 'nsenter is required' "$work/err" || fail "missing nsenter was not reported"
[ ! -s "$work/ip.log" ] || fail "missing nsenter still ran ip"

ln -s "$(command -v nsenter)" "$tools/nsenter"
if PATH="$tools" "$helper" "$@" >"$work/out" 2>"$work/err"; then
  fail "missing ip was accepted"
fi
grep -q 'ip is required' "$work/err" || fail "missing ip was not reported"

record "$client" "/$project-client-1" running true "$pid" host "" false "$project" client "$work/netns/abc"
expect_reject "host network" "$@"
base_record ""
record "$client" "/$project-client-1" running true "$pid" bridge host false "$project" client "$work/netns/abc"
expect_reject "host pid" "$@"
base_record ""
record "$client" "/$project-client-1" running true "$pid" bridge "" true "$project" client "$work/netns/abc"
expect_reject "privileged" "$@"
base_record ""
record "$client" "/$project-client-1" exited false "$pid" bridge "" false "$project" client "$work/netns/abc"
expect_reject "not running" "$@"
base_record ""
record "$client" "/$project-client-1" running true 1 bridge "" false "$project" client "$work/netns/abc"
expect_reject "pid 1" "$@"
base_record ""
record "$client" "/$project-client-1" running true 0 bridge "" false "$project" client "$work/netns/abc"
expect_reject "pid 0" "$@"
base_record ""
record "$client" "/wrong-client-1" running true "$pid" bridge "" false wrongprj client "$work/netns/abc"
expect_reject "project mismatch" "$@"
base_record ""
record "$client" "/$project-proxy-1" running true "$pid" bridge "" false "$project" proxy "$work/netns/abc"
expect_reject "service mismatch" "$@"
base_record ""
record "$client" "/$project-client-1" running true "$pid" bridge "" false "$project" client "/proc/1/ns/net"
expect_reject "host path" "$@"
base_record ""
record "$client" "/$project-client-1" running true "$pid" bridge "" false "$project" client "$work/netns/../hostns"
expect_reject "path escape" "$@"
base_record ""
ln -f "$work/hostns" "$work/netns/samehost"
record "$client" "/$project-client-1" running true "$pid" bridge "" false "$project" client "$work/netns/samehost"
# pid ns still points at abc, so this fails as a pid mismatch or as the host inode.
# Point the pid ns at the host inode too, otherwise the host check is not the one we hit.
rm -f "$work/proc/$pid/ns/net"
ln "$work/hostns" "$work/proc/$pid/ns/net"
expect_reject "host inode" "$@"
rm -f "$work/proc/$pid/ns/net"
ln "$work/netns/abc" "$work/proc/$pid/ns/net"
base_record ""
ln "$work/netns/abc" "$work/netns/shared"
record "$other" "/vvrstffffff-client-1" exited false 0 bridge "" false vvrstffffff client "$work/netns/shared"
expect_reject "shared sandbox" "$@"
record "$other" "/vvrstffffff-client-1" exited false 0 bridge "" false vvrstffffff client "$work/netns/other"
base_record ""
rm -f "$work/proc/$pid/ns/net"
printf '%s\n' 'reused' > "$work/proc/$pid/ns/net"
expect_reject "reused pid" "$@"
rm -f "$work/proc/$pid/ns/net"
ln "$work/netns/abc" "$work/proc/$pid/ns/net"
printf '0::/docker/not-the-client\n' > "$work/proc/$pid/cgroup"
expect_reject "cgroup mismatch" "$@"
printf '0::/docker/%s\n' "$client" > "$work/proc/$pid/cgroup"
base_record ""
base_record 2
# second inspect exits
record "$client" "/$project-client-1" exited false 0 bridge "" false "$project" client "$work/netns/abc" 2
expect_reject "stale reinspect" "$@"
rm -f "$work/inspect-$client-2"
base_record ""
record "$client" "/$project-client-1" running true 5151 bridge "" false "$project" client "$work/netns/abc" 2
expect_reject "changed pid" "$@"
rm -f "$work/inspect-$client-2"
printf 'short\n' > "$work/inspect-$client"
expect_reject "malformed inspect" "$@"
base_record ""

rm -f "$work"/count-* "$work/inspect-$client-"[0-9]*
routes_before=$(/usr/sbin/ip route show)
: > "$work/nsenter.log"
: > "$work/ip.log"
PATH="$stubs:$tools" "$helper" "$@" >"$work/out" 2>"$work/err" || {
  cat "$work/err" >&2
  fail "pinned client route was rejected"
}
routes_after=$(/usr/sbin/ip route show)
[ "$routes_before" = "$routes_after" ] || fail "the host routing table changed"
grep -q -- '--net=/proc/self/fd/9 --' "$work/nsenter.log" || fail "entry did not use the pinned descriptor"
if grep -E '(^|[[:space:]])-t([[:space:]]|$)|--target' "$work/nsenter.log" >/dev/null; then
  fail "entry used a process id"
fi
grep -qx "route replace ${dest}/32 via ${via}" "$work/ip.log" || fail "route command was not the one fixture address"
echo "pinned descriptor accepted the stage client and rejected the unsafe targets"
echo "fixture left at $keep"

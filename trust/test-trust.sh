#!/bin/sh
# THE IMAGE TRUST TEST (epic qits-2524): proves qits-trust-layout and qits-trust-init end to end, as
# a non-root uid, against a throwaway CA served by `openssl s_server`. It also proves qits-trust-
# init's /etc/qits/init.d hook mechanism (epic qits-2525, qits-2656): a hook's export reaching the
# exec'd command, a failing hook not stopping the exec, name order, and no hook directory changing
# nothing — all through the QITS_INIT_HOOK_DIR override, so this needs no root and no real
# /etc/qits/init.d either.
#
#   sh trust/test-trust.sh               simulate: lay out a temp copy of this machine's system bundle
#                                        and JDK cacerts (QITS_TRUST_DIR, QITS_TRUST_SYSTEM_BUNDLE, a
#                                        temp JAVA_HOME) and run the scripts from this directory. No
#                                        root, no docker. Run it before pushing a change to trust/.
#                                        TRUST_TEST_CACERTS=<file> simulates with that JDK store.
#   sh trust/test-trust.sh --installed   inside a built image (the `check` stages of ci-slot and
#                                        node-browser-base): the scripts on PATH, the real
#                                        /etc/ssl/qits, and the image's ENV, which it asserts too.
#
# A client the machine does not carry is reported `skip`; TRUST_TEST_STRICT=1 makes a skip fail
# (keytool only counts where the layout found a JDK). Needs openssl, which both images carry as a
# dependency of ca-certificates.
set -u

mode=simulate
if [ "${1:-}" = --installed ]; then mode=installed; fi

failures=0
skips=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1" >&2; failures=$((failures + 1)); }
skip() {
  echo "skip  $1"
  skips=$((skips + 1))
  if [ "${TRUST_TEST_STRICT:-0}" = 1 ]; then fail "strict: $1 was skipped"; fi
}
has() { command -v "$1" >/dev/null 2>&1; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }

if [ "$(id -u)" = 0 ]; then
  echo "test-trust: run me as a non-root uid; the point is that the init needs no root" >&2
  exit 2
fi
has openssl || { echo "test-trust: openssl is required" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-trust.XXXXXX")
server_pid=''
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
export HOME="$tmp/home"
mkdir -p "$HOME"

# THE SUBJECT. Simulate builds a layout of its own in $tmp; installed uses the image's.
if [ "$mode" = simulate ]; then
  here=$(cd "$(dirname "$0")" && pwd)
  layout="$here/qits-trust-layout"
  init="$here/qits-trust-init"
  export QITS_TRUST_DIR="$tmp/qits"
  export QITS_RUN_DIR="$tmp/run/qits"
  export QITS_TRUST_SYSTEM_BUNDLE="$tmp/system/ca-certificates.crt"
  mkdir -p "$tmp/system"
  cp /etc/ssl/certs/ca-certificates.crt "$QITS_TRUST_SYSTEM_BUNDLE"
  system_bundle=$QITS_TRUST_SYSTEM_BUNDLE
  # A JDK store to simulate with: the one the keytool on PATH ships, copied behind a symlink the way
  # Debian and Adoptium packages install it.
  # TRUST_TEST_CACERTS names another store to simulate with (a PKCS12 one, say).
  cacerts_source=${TRUST_TEST_CACERTS:-}
  if [ -z "$cacerts_source" ] && has keytool; then
    jdk=$(dirname "$(dirname "$(readlink -f "$(command -v keytool)")")")
    if [ -e "$jdk/lib/security/cacerts" ]; then cacerts_source=$(readlink -f "$jdk/lib/security/cacerts"); fi
  fi
  if [ -n "$cacerts_source" ]; then
    export JAVA_HOME="$tmp/jdk"
    mkdir -p "$JAVA_HOME/lib/security" "$tmp/system/java"
    cp "$cacerts_source" "$tmp/system/java/cacerts"
    ln -s "$tmp/system/java/cacerts" "$JAVA_HOME/lib/security/cacerts"
  else
    unset JAVA_HOME
  fi
  dir=$QITS_TRUST_DIR
  public_copy=$(cat "$system_bundle" | sha256sum)

  # 1. The layout, twice: the second run must change nothing.
  if sh "$layout" >/dev/null && sh "$layout" >/dev/null; then pass "layout runs, twice"; else fail "layout"; fi
  # ...and once more after the bundle went back to a regular file, as update-ca-certificates leaves it.
  rm -f "$system_bundle" && cp /etc/ssl/certs/ca-certificates.crt "$system_bundle"
  if sh "$layout" >/dev/null && [ -L "$system_bundle" ]; then
    pass "layout re-links a bundle rewritten as a regular file"
  else
    fail "layout after a rewritten bundle"
  fi
  bundle_env=$dir/ca-bundle.pem
else
  layout=''
  init=/usr/local/bin/qits-trust-init
  dir=/etc/ssl/qits
  QITS_RUN_DIR=/run/qits
  system_bundle=/etc/ssl/certs/ca-certificates.crt
  public_copy=$(sha256sum < "$dir/public-bundle.pem")
  bundle_env=$dir/ca-bundle.pem
  # The image contract: scripts, links, modes and ENV.
  for script in /usr/local/bin/qits-trust-layout /usr/local/bin/qits-trust-init; do
    if [ -x "$script" ]; then pass "$script is executable"; else fail "$script is missing or not executable"; fi
  done
  if [ "$(readlink -f "$system_bundle")" = "$dir/ca-bundle.pem" ]; then
    pass "$system_bundle links to $dir/ca-bundle.pem"
  else
    fail "$system_bundle resolves to $(readlink -f "$system_bundle"), not $dir/ca-bundle.pem"
  fi
  if [ "$(stat -c %a "$dir")" = 777 ]; then pass "$dir is mode 0777"; else fail "$dir is mode $(stat -c %a "$dir")"; fi
  for file in public-bundle.pem ca-bundle.pem anchors.pem; do
    if [ -f "$dir/$file" ] && [ "$(stat -c %a "$dir/$file")" = 666 ]; then
      pass "$dir/$file is present, mode 0666"
    else
      fail "$dir/$file is missing or not mode 0666"
    fi
  done
  if [ -n "${JAVA_HOME:-}" ] && [ -e "$JAVA_HOME/lib/security/cacerts" ]; then
    if [ "$(readlink -f "$JAVA_HOME/lib/security/cacerts")" = "$dir/java-cacerts" ] && [ -f "$dir/public-cacerts" ]; then
      pass "\$JAVA_HOME/lib/security/cacerts links to $dir/java-cacerts"
    else
      fail "\$JAVA_HOME/lib/security/cacerts resolves to $(readlink -f "$JAVA_HOME/lib/security/cacerts")"
    fi
  fi
  for name in NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE PIP_CERT SSL_CERT_FILE CURL_CA_BUNDLE GIT_SSL_CAINFO; do
    value=$(printenv "$name")
    if [ "$value" = "$dir/ca-bundle.pem" ]; then pass "ENV $name"; else fail "ENV $name is '$value'"; fi
  done
fi

# Where the layout linked a JDK store. keytool reads it through $JAVA_HOME's link, never directly.
java_store=''
if [ -n "${JAVA_HOME:-}" ] && [ -e "$dir/java-cacerts" ]; then java_store="$JAVA_HOME/lib/security/cacerts"; fi
keytool=''
if has keytool; then keytool=$(command -v keytool)
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ]; then keytool=$JAVA_HOME/bin/keytool; fi

# 2. Without QITS_TRUST_ANCHORS: public trust, unchanged.
if env -u QITS_TRUST_ANCHORS sh "$init" true 2>"$tmp/init.err" && ! [ -s "$tmp/init.err" ]; then
  pass "init without anchors: quiet, exit 0"
else
  fail "init without anchors: $(cat "$tmp/init.err")"
fi
if [ "$(sha256sum < "$system_bundle")" = "$public_copy" ] && [ "$(sha256sum < "$dir/ca-bundle.pem")" = "$public_copy" ]; then
  pass "without anchors the system bundle equals the public bundle"
else
  fail "without anchors the system bundle differs from the public bundle"
fi
if [ -n "$java_store" ]; then
  if cmp -s "$dir/java-cacerts" "$dir/public-cacerts"; then pass "without anchors java-cacerts equals public-cacerts"
  else fail "without anchors java-cacerts differs from public-cacerts"; fi
fi
# A public site still verifies, where the network reaches one. Only a certificate error fails it.
if has curl; then
  CURL_CA_BUNDLE=$bundle_env curl -sS --max-time 15 -o /dev/null https://example.com 2>"$tmp/curl.err"
  status=$?
  case $status in
    0) pass "public https://example.com verifies without anchors" ;;
    35|60|77) fail "public https://example.com: $(cat "$tmp/curl.err")" ;;
    *) skip "public https://example.com unreachable (curl $status)" ;;
  esac
fi

# 3. A throwaway CA and a leaf for trust.test, served on a free localhost port.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 1 \
  -subj '/CN=qits trust test CA' -keyout "$tmp/ca.key" -out "$tmp/ca.pem" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
  -subj '/CN=trust.test' -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" 2>/dev/null
printf 'subjectAltName=DNS:trust.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$tmp/leaf.ext"
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" -CAcreateserial \
  -days 1 -extfile "$tmp/leaf.ext" -out "$tmp/leaf.pem" 2>/dev/null \
  || { echo "test-trust: could not make the test certificates" >&2; exit 2; }

port=''
attempt=0
while [ -z "$port" ] && [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  candidate=$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))
  openssl s_server -quiet -www -accept "127.0.0.1:$candidate" \
    -cert "$tmp/leaf.pem" -key "$tmp/leaf.key" </dev/null >"$tmp/server.log" 2>&1 &
  server_pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
    if openssl s_client -connect "127.0.0.1:$candidate" </dev/null >/dev/null 2>&1; then
      port=$candidate
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$port" ]; then kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=''; fi
done
[ -n "$port" ] || { echo "test-trust: openssl s_server never came up" >&2; exit 2; }
url="https://trust.test:$port/"

# THE CLIENTS. Each probe succeeds only past TLS, reading only the image's paths and ENV names, and
# leaves its error in $tmp/probe.err.
probe_curl() {
  CURL_CA_BUNDLE=$bundle_env curl -sS --max-time 10 -o /dev/null \
    --resolve "trust.test:$port:127.0.0.1" "$url" 2>"$tmp/probe.err"
}
probe_curl_system() {
  curl -sS --max-time 10 -o /dev/null --cacert "$system_bundle" \
    --resolve "trust.test:$port:127.0.0.1" "$url" 2>"$tmp/probe.err"
}
probe_git() {
  # s_server's status page is not a git repository: git must get that far and fail on it, not on TLS.
  GIT_SSL_CAINFO=$bundle_env GIT_TERMINAL_PROMPT=0 git -c "http.curloptResolve=trust.test:$port:127.0.0.1" \
    ls-remote "https://trust.test:$port/x" >/dev/null 2>"$tmp/probe.err"
  ! grep -qiE 'certificate|SSL|TLS' "$tmp/probe.err"
}
probe_node() {
  # fetch has no --resolve; trust.test is answered by patching dns.lookup, which undici dials through.
  NODE_EXTRA_CA_CERTS=$bundle_env node -e '
    const dns = require("dns"); const lookup = dns.lookup;
    dns.lookup = (host, opts, cb) => host === "trust.test"
      ? (typeof opts === "function" ? opts : cb)(null, opts && opts.all ? [{ address: "127.0.0.1", family: 4 }] : "127.0.0.1", 4)
      : lookup(host, opts, cb);
    fetch(process.argv[1]).then(r => { if (!r.ok) throw new Error("HTTP " + r.status); },
      e => { console.error(e.cause ? e.cause.code || e.cause.message : e.message); process.exit(1); });
  ' "$url" 2>"$tmp/probe.err"
}
probe_python3() {
  SSL_CERT_FILE=$bundle_env python3 -c '
import socket, sys, urllib.request
real = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **k: real("127.0.0.1" if host == "trust.test" else host, *a, **k)
urllib.request.urlopen(sys.argv[1], timeout=10).read()
' "$url" 2>"$tmp/probe.err"
}
probe_keytool() {
  [ -n "$keytool" ] && "$keytool" -list -keystore "$java_store" -storepass changeit 2>"$tmp/probe.err" \
    | grep -q '^qits-platform-ca-'
}
probe_java() {
  # A JVM's own TLS, reading $JAVA_HOME's default store as Maven does; jdk.net.hosts.file is the JDK's
  # --resolve. Single-file source launch: no build, one JVM start.
  printf '127.0.0.1 trust.test\n' > "$tmp/hosts"
  cat > "$tmp/Probe.java" <<'JAVA'
public class Probe {
  public static void main(String[] args) throws Exception {
    var connection = (javax.net.ssl.HttpsURLConnection) new java.net.URI(args[0]).toURL().openConnection();
    connection.setConnectTimeout(10000);
    connection.setReadTimeout(10000);
    connection.getResponseCode();
  }
}
JAVA
  # shellcheck disable=SC2086 # $java_store_opt is zero or one word on purpose
  "$java" $java_store_opt -Djdk.net.hosts.file="$tmp/hosts" "$tmp/Probe.java" "$url" 2>"$tmp/probe.err"
}
# Installed, the JVM's default store IS the link. Simulated, the JDK on PATH reads its own real store,
# so it is pointed at the simulated link explicitly (and still loads it with no password, as the
# default store is loaded).
java=''
java_store_opt=''
if [ "$mode" = installed ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  java=$JAVA_HOME/bin/java
elif [ "$mode" = simulate ] && [ -n "$keytool" ] && [ -x "$(dirname "$(readlink -f "$keytool")")/java" ]; then
  java=$(dirname "$(readlink -f "$keytool")")/java
  java_store_opt=-Djavax.net.ssl.trustStore=$java_store
fi
clients="curl:curl curl_system:curl git:git node:node python3:python3"
if [ -n "$java_store" ]; then clients="$clients keytool:keytool"; fi
if [ -n "$java_store" ] && [ -n "$java" ]; then clients="$clients java:java"; fi
describe() {
  case $1 in
    curl) echo "curl (CURL_CA_BUNDLE)" ;;
    curl_system) echo "curl --cacert $system_bundle (the system bundle link)" ;;
    git) echo "git ls-remote (GIT_SSL_CAINFO)" ;;
    node) echo "node fetch (NODE_EXTRA_CA_CERTS)" ;;
    python3) echo "python3 urllib (SSL_CERT_FILE)" ;;
    keytool) echo "keytool -list \$JAVA_HOME/lib/security/cacerts" ;;
    java) echo "java HttpsURLConnection (\$JAVA_HOME/lib/security/cacerts)" ;;
  esac
}

# Before the anchor: no client may trust the test CA, or the rest proves nothing.
for entry in $clients; do
  probe=${entry%%:*} tool=${entry#*:}
  if [ "$tool" != java ] && ! has "$tool"; then continue; fi
  if "probe_$probe"; then fail "$(describe "$probe") trusted the test CA before any anchor was given"
  else pass "$(describe "$probe") refuses the test CA without anchors"; fi
done

# 5. The init with one anchor, timed. The anchor arrives with indentation and a stray block of
# non-certificate PEM, as a hand-pasted value might.
anchors=$(printf '  -----BEGIN PRIVATE KEY-----\n  bm90IGEga2V5\n  -----END PRIVATE KEY-----\n'; sed 's/^/  /' "$tmp/ca.pem")
start=$(now_ms)
QITS_TRUST_ANCHORS=$anchors sh "$init" sh -c 'echo ran' >"$tmp/init.out" 2>"$tmp/init.err"
status=$?
elapsed=$(($(now_ms) - start))
if [ "$status" = 0 ] && [ "$(cat "$tmp/init.out")" = ran ] && ! [ -s "$tmp/init.err" ]; then
  pass "init with one anchor: quiet, execs the command"
else
  fail "init with one anchor: exit $status, stdout '$(cat "$tmp/init.out")', stderr '$(cat "$tmp/init.err")'"
fi
if [ "$elapsed" -le 2000 ]; then pass "init with one anchor took ${elapsed} ms (budget 2000)"
else fail "init with one anchor took ${elapsed} ms (budget 2000)"; fi
if [ "$(grep -c 'BEGIN CERTIFICATE' "$dir/anchors.pem")" = 1 ] && ! grep -q 'PRIVATE KEY' "$dir/anchors.pem" "$dir/ca-bundle.pem"; then
  pass "anchors.pem holds the one certificate and nothing else"
else
  fail "anchors.pem does not hold exactly the one certificate"
fi

# Every client, past TLS, as this non-root uid.
for entry in $clients; do
  probe=${entry%%:*} tool=${entry#*:}
  if [ "$tool" != java ] && ! has "$tool"; then skip "$tool is not installed"; continue; fi
  if "probe_$probe"; then pass "$(describe "$probe") trusts the anchor"
  else fail "$(describe "$probe"): $(tr '\n' ' ' < "$tmp/probe.err" | cut -c1-200)"; fi
done
if [ -z "$java_store" ] && [ "$mode" = simulate ]; then skip "no JDK cacerts to simulate with"; fi

# Back to no anchors: the anchor is gone again.
env -u QITS_TRUST_ANCHORS sh "$init" true
if [ "$(sha256sum < "$dir/ca-bundle.pem")" = "$public_copy" ] && ! [ -s "$dir/anchors.pem" ] \
  && { [ -z "$java_store" ] || cmp -s "$dir/java-cacerts" "$dir/public-cacerts"; }; then
  pass "a start without anchors resets every store to public"
else fail "a start without anchors left the anchor behind"; fi

# 4. A malformed QITS_TRUST_ANCHORS: still execs, exactly one stderr line, public trust.
for case in 'not a certificate at all' \
  "$(printf -- '-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydA==\n-----END CERTIFICATE-----')"; do
  QITS_TRUST_ANCHORS=$case sh "$init" sh -c 'echo ran' >"$tmp/init.out" 2>"$tmp/init.err"
  status=$?
  if [ "$status" = 0 ] && [ "$(cat "$tmp/init.out")" = ran ] && [ "$(wc -l < "$tmp/init.err")" = 1 ] \
    && grep -q '^qits-trust-init: .*; continuing with public trust$' "$tmp/init.err" \
    && [ "$(sha256sum < "$dir/ca-bundle.pem")" = "$public_copy" ]; then
    pass "malformed anchors: execs, public trust, one line: $(cat "$tmp/init.err")"
  else
    fail "malformed anchors: exit $status, stdout '$(cat "$tmp/init.out")', stderr '$(cat "$tmp/init.err")'"
  fi
done
# The exit status is the command's own.
QITS_TRUST_ANCHORS='garbage' sh "$init" sh -c 'exit 7' 2>/dev/null
status=$?
if [ "$status" = 7 ]; then pass "the command's exit status passes through"; else fail "exit status $status, expected 7"; fi

# 6. The init hook directory (qits-2656): /etc/qits/init.d/*.sh, sourced in name order, each inside a
# guard, just before the exec. QITS_INIT_HOOK_DIR overrides the directory for all of this, the way
# QITS_TRUST_DIR overrides the trust store, so none of it needs root or a real /etc/qits/init.d.
hookdir="$tmp/init.d"
mkdir -p "$hookdir"

# No hook directory at all, two ways: the real default path (absent on this machine and on both
# images this test runs in, since only qits-workspace-oci ever populates it) and an explicit
# override at a path that does not exist. Either way, behaviour is exactly the exit-status-passthrough
# case above with no hook-related stderr.
if [ -d /etc/qits/init.d ]; then
  skip "a real /etc/qits/init.d exists on this machine; the override-to-a-missing-path case still runs"
else
  env -u QITS_TRUST_ANCHORS -u QITS_INIT_HOOK_DIR sh "$init" sh -c 'exit 7' 2>"$tmp/hook.err"
  status=$?
  if [ "$status" = 7 ] && ! [ -s "$tmp/hook.err" ]; then
    pass "no /etc/qits/init.d: unchanged behaviour (quiet, exit status passes through)"
  else
    fail "no /etc/qits/init.d changed behaviour: exit $status, stderr '$(cat "$tmp/hook.err")'"
  fi
fi
QITS_INIT_HOOK_DIR="$tmp/no-such-init-d" env -u QITS_TRUST_ANCHORS sh "$init" sh -c 'exit 7' 2>"$tmp/hook.err"
status=$?
if [ "$status" = 7 ] && ! [ -s "$tmp/hook.err" ]; then
  pass "QITS_INIT_HOOK_DIR at a missing path: unchanged behaviour"
else
  fail "a missing QITS_INIT_HOOK_DIR changed behaviour: exit $status, stderr '$(cat "$tmp/hook.err")'"
fi

# A hook's export, visible to `qits-trust-init env` (the exec'd command) because the hook is sourced,
# not run.
cat >"$hookdir/10-export.sh" <<'HOOK'
export HOOK_TEST_EXPORT=visible
HOOK
hook_env=$(QITS_INIT_HOOK_DIR="$hookdir" env -u QITS_TRUST_ANCHORS sh "$init" env 2>"$tmp/hook.err")
if printf '%s\n' "$hook_env" | grep -qx 'HOOK_TEST_EXPORT=visible' && ! [ -s "$tmp/hook.err" ]; then
  pass "a hook's export is visible to qits-trust-init env"
else
  fail "hook export not visible: stderr '$(cat "$tmp/hook.err")'"
fi
rm -f "$hookdir/10-export.sh"

# A failing hook (set -e, then a failing command) does not stop the exec, does not block a later hook
# in name order, and is reported with exactly one stderr line naming it.
cat >"$hookdir/10-bad.sh" <<'HOOK'
set -e
false
export HOOK_TEST_BAD=should_not_appear
HOOK
cat >"$hookdir/20-after-bad.sh" <<'HOOK'
export HOOK_TEST_AFTER_BAD=ran
HOOK
hook_env=$(QITS_INIT_HOOK_DIR="$hookdir" env -u QITS_TRUST_ANCHORS sh "$init" sh -c 'echo execed; env' 2>"$tmp/hook.err")
status=$?
if [ "$status" = 0 ] && printf '%s\n' "$hook_env" | grep -q '^execed$' \
  && printf '%s\n' "$hook_env" | grep -qx 'HOOK_TEST_AFTER_BAD=ran' \
  && ! printf '%s\n' "$hook_env" | grep -q '^HOOK_TEST_BAD'; then
  pass "a failing hook does not stop the exec, and a later hook still runs"
else
  fail "a failing hook stopped the exec or blocked a later hook: exit $status"
fi
if [ "$(wc -l <"$tmp/hook.err")" = 1 ] && grep -qF "qits-trust-init: hook $hookdir/10-bad.sh failed" "$tmp/hook.err"; then
  pass "the failing hook is reported with exactly one stderr line naming it"
else
  fail "failing-hook stderr was '$(cat "$tmp/hook.err")'"
fi
rm -f "$hookdir/10-bad.sh" "$hookdir/20-after-bad.sh"

# Name order: a later hook (by filename) sees an earlier one's export already applied. Reversed, a
# hook named 10-a running after 20-b would overwrite instead of appending, so the exact value "a-b"
# is only reachable in 10-a, 20-b order.
cat >"$hookdir/10-a.sh" <<'HOOK'
export HOOK_TEST_ORDER=a
HOOK
cat >"$hookdir/20-b.sh" <<'HOOK'
export HOOK_TEST_ORDER="${HOOK_TEST_ORDER:-unset}-b"
HOOK
hook_env=$(QITS_INIT_HOOK_DIR="$hookdir" env -u QITS_TRUST_ANCHORS sh "$init" env 2>"$tmp/hook.err")
if printf '%s\n' "$hook_env" | grep -qx 'HOOK_TEST_ORDER=a-b' && ! [ -s "$tmp/hook.err" ]; then
  pass "hooks run in name order"
else
  fail "hooks did not run in name order: $(printf '%s\n' "$hook_env" | grep '^HOOK_TEST_ORDER='), stderr '$(cat "$tmp/hook.err")'"
fi
rm -f "$hookdir/10-a.sh" "$hookdir/20-b.sh"

# 7. The workload certificate hook (epic qits-2626, qits-2762): 40-workload-certificate.sh, sourced
# from a hook directory of the test's own (a copy of the installed hook, or of this directory's), with
# a fake `qits` on PATH that records how it was started. Its parent, /run/qits, is 1777.
if [ "$(stat -c %a "$QITS_RUN_DIR" 2>/dev/null)" = 1777 ]; then
  pass "the layout makes $QITS_RUN_DIR 1777"
else
  fail "$QITS_RUN_DIR is $(stat -c %a "$QITS_RUN_DIR" 2>/dev/null || echo missing), not 1777"
fi
# Which hook: this directory's in a simulation, the installed one in an image. Only node-browser-base
# (and the images on it) installs the hook; ci-slot runs this test too and carries none, by design
# (CI slots hold no workload certificate), so there the checks below do not apply and are not counted
# as skips: TRUST_TEST_STRICT would otherwise fail an image for something it should not have.
# QITS_WORKLOAD_HOOK names another file, for running the absent case in a simulation.
if [ "$mode" = simulate ]; then
  workload_hook=${QITS_WORKLOAD_HOOK:-$here/40-workload-certificate.sh}
else
  workload_hook=${QITS_WORKLOAD_HOOK:-/etc/qits/init.d/40-workload-certificate.sh}
fi
if ! [ -f "$workload_hook" ] && ls -a "$(dirname "$workload_hook")" 2>/dev/null | grep -qx "$(basename "$workload_hook")"; then
  # Listed but not reachable: a directory without x for this uid (COPY --chmod=0644 made one), so
  # qits-trust-init would see the hook's name and never run it.
  fail "$workload_hook is installed but uid $(id -u) cannot reach it (is $(dirname "$workload_hook") missing x?)"
elif ! [ -f "$workload_hook" ]; then
  echo "n/a   no $workload_hook in this image (ci-slot carries none): the workload hook checks do not apply"
else
  whookdir="$tmp/init.d-workload"
  mkdir -p "$whookdir" "$tmp/fakebin" "$tmp/fakebin-old"
  cp "$workload_hook" "$whookdir/40-workload-certificate.sh"
  cat >"$tmp/fakebin/qits" <<FAKE
#!/bin/sh
if [ "\$3" = --help ]; then echo "Usage: qits certificate keep [-hV] [--dir=<dir>]"; exit 0; fi
echo "\$*" > "$tmp/qits-started"
FAKE
  # An old qits answers `certificate keep --help` with its top-level usage and exit 0, as picocli does.
  cat >"$tmp/fakebin-old/qits" <<'FAKE'
#!/bin/sh
echo "Unmatched arguments from index 0: 'certificate', 'keep'" >&2
echo "Usage: qits [-hV] [COMMAND]"
exit 0
FAKE
  chmod +x "$tmp/fakebin/qits" "$tmp/fakebin-old/qits"
  wdir="$tmp/run-workload/workload"
  started_within() {
    i=0
    while [ "$i" -lt 50 ]; do
      [ -s "$tmp/qits-started" ] && return 0
      sleep 0.1
      i=$((i + 1))
    done
    return 1
  }

  # A token and a qits with `certificate keep`: keep starts in the background, and the exec'd command
  # sees QITS_WORKLOAD_CERT_DIR.
  rm -f "$tmp/qits-started"
  hook_env=$(PATH="$tmp/fakebin:$PATH" QITS_TOKEN=qits_tok_test QITS_WORKLOAD_CERT_DIR="$wdir" \
    QITS_INIT_HOOK_DIR="$whookdir" env -u QITS_TRUST_ANCHORS sh "$init" env 2>"$tmp/hook.err")
  if printf '%s\n' "$hook_env" | grep -qx "QITS_WORKLOAD_CERT_DIR=$wdir" && started_within \
    && [ "$(cat "$tmp/qits-started")" = "certificate keep --dir $wdir" ] && ! [ -s "$tmp/hook.err" ]; then
    pass "with a token and qits, the hook starts qits certificate keep and exports QITS_WORKLOAD_CERT_DIR"
  else
    fail "workload hook: started '$(cat "$tmp/qits-started" 2>/dev/null)', stderr '$(cat "$tmp/hook.err")'"
  fi

  # No token: nothing started, nothing exported, nothing said.
  rm -f "$tmp/qits-started"
  hook_env=$(PATH="$tmp/fakebin:$PATH" QITS_INIT_HOOK_DIR="$whookdir" \
    env -u QITS_TRUST_ANCHORS -u QITS_TOKEN -u QITS_WORKLOAD_CERT_DIR sh "$init" sh -c 'echo execed; env' 2>"$tmp/hook.err")
  sleep 0.3
  if printf '%s\n' "$hook_env" | grep -q '^execed$' && ! printf '%s\n' "$hook_env" | grep -q '^QITS_WORKLOAD_CERT_DIR=' \
    && ! [ -e "$tmp/qits-started" ] && ! [ -s "$tmp/hook.err" ]; then
    pass "without a token the workload hook does nothing"
  else
    fail "workload hook without a token: stderr '$(cat "$tmp/hook.err")'"
  fi

  # A token but no qits on PATH: the same.
  hook_env=$(PATH="/usr/bin:/bin" QITS_TOKEN=qits_tok_test QITS_INIT_HOOK_DIR="$whookdir" \
    env -u QITS_TRUST_ANCHORS -u QITS_WORKLOAD_CERT_DIR sh "$init" sh -c 'echo execed; env' 2>"$tmp/hook.err")
  if ! PATH="/usr/bin:/bin" command -v qits >/dev/null 2>&1; then
    if printf '%s\n' "$hook_env" | grep -q '^execed$' && ! [ -s "$tmp/hook.err" ]; then
      pass "without a qits CLI the workload hook does nothing and the start goes on"
    else
      fail "workload hook without qits: stderr '$(cat "$tmp/hook.err")'"
    fi
  else
    skip "a qits on /usr/bin or /bin: cannot test a container without one here"
  fi

  # A qits too old for `certificate keep`: one stderr line, no export, the exec still happens.
  hook_env=$(PATH="$tmp/fakebin-old:$PATH" QITS_TOKEN=qits_tok_test QITS_INIT_HOOK_DIR="$whookdir" \
    env -u QITS_TRUST_ANCHORS -u QITS_WORKLOAD_CERT_DIR sh "$init" sh -c 'echo execed; env' 2>"$tmp/hook.err")
  status=$?
  if [ "$status" = 0 ] && printf '%s\n' "$hook_env" | grep -q '^execed$' \
    && ! printf '%s\n' "$hook_env" | grep -q '^QITS_WORKLOAD_CERT_DIR=' && [ "$(wc -l <"$tmp/hook.err")" = 1 ] \
    && grep -q "^qits-workload-certificate: .*; continuing without a workload certificate$" "$tmp/hook.err"; then
    pass "a qits without certificate keep prints one line and the start goes on"
  else
    fail "workload hook with an old qits: exit $status, stderr '$(cat "$tmp/hook.err")'"
  fi
  rm -rf "$whookdir"
fi

echo "test-trust ($mode): $failures failed, $skips skipped"
[ "$failures" = 0 ]

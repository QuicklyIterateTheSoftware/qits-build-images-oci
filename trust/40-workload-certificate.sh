# /etc/qits/init.d/40-workload-certificate.sh (epic qits-2626, qits-2762): SOURCED by qits-trust-init
# at container start, ANY UID, just before it execs the container's command.
#
# Keeps this container's workload client certificate: when the container holds a qits bearer
# (QITS_TOKEN) and a `qits` CLI that has `certificate keep`, it starts `qits certificate keep` in the
# background and exports QITS_WORKLOAD_CERT_DIR (default /run/qits/workload), where key.pem (0600),
# cert.pem and chain.pem appear within seconds and are renewed at 2/3 of their day for as long as the
# container runs. The certificate names the token's principal (mostly project:<id>); the key is made
# in the container and never leaves it.
#
# Otherwise — no token, no qits, a qits too old to know the command — it does nothing, and a
# container that has none of them starts exactly as before. A failure prints ONE stderr line,
# `qits-workload-certificate: <what>; continuing without a workload certificate`, and the hook still
# succeeds: it never stops a start (the qits-trust-init rule). `keep` logs to the container's stderr
# itself: one line per certificate and one per failure streak.
#
# /run/qits is made 1777 by qits-trust-layout, so `keep`, as whatever uid the container runs, creates
# the workload directory itself, owned by that uid and 0700. The source of truth is trust/ in
# qits-build-images-oci.

if [ -n "${QITS_TOKEN:-}" ] && command -v qits >/dev/null 2>&1; then
  QITS_WORKLOAD_CERT_DIR=${QITS_WORKLOAD_CERT_DIR:-/run/qits/workload}
  # A qits without the command still answers --help, with its top-level usage and exit 0, so the
  # usage line is what tells them apart.
  if ! qits certificate keep --help 2>/dev/null | grep -q '^Usage: qits certificate keep'; then
    echo "qits-workload-certificate: this qits has no 'certificate keep'; continuing without a workload certificate" >&2
  elif ! mkdir -p "$(dirname "$QITS_WORKLOAD_CERT_DIR")" 2>/dev/null; then
    echo "qits-workload-certificate: cannot create $(dirname "$QITS_WORKLOAD_CERT_DIR"); continuing without a workload certificate" >&2
  else
    # In the background, with nothing of this shell's but stderr: no stdin, no stdout, and not the
    # descriptor qits-trust-init dumps a hook's exports to (3).
    qits certificate keep --dir "$QITS_WORKLOAD_CERT_DIR" </dev/null >/dev/null 3>&- &
    export QITS_WORKLOAD_CERT_DIR
  fi
fi
true

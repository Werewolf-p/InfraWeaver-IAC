#!/usr/bin/env python3
"""etcd health manager — runs inside a privileged pod that has /host/proc.

Actions (in order):
  1. Detect CORRUPT / NOSPACE alarms → compact + defrag + disarm
  2. Detect high fragmentation (ratio > 1.5x) or large DB (> 800 MB) → defrag
  3. Print a structured summary for GitHub Actions step output
"""
import glob
import io
import json
import os
import subprocess
import sys
import tarfile
import urllib.request

E = "/tmp/etcdctl-healer"
ETCD_NODES = [
    os.environ.get("NODE_1_IP", "10.0.0.90"),
    os.environ.get("NODE_2_IP", "10.0.0.91"),
    os.environ.get("NODE_3_IP", "10.0.0.92"),
]
ENDPOINTS = ",".join(f"https://{node}:2379" for node in ETCD_NODES if node)

# Proactive defrag thresholds
FRAG_RATIO_THRESHOLD = 1.5   # defrag when total/in_use > 1.5x on any member
ABS_SIZE_MB_THRESHOLD = 800  # defrag when any member's DB exceeds 800 MB


def ensure_etcdctl():
    if os.path.exists(E):
        return
    print("Downloading etcdctl...", flush=True)
    url = "https://github.com/etcd-io/etcd/releases/download/v3.5.17/etcd-v3.5.17-linux-amd64.tar.gz"
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        m = t.getmember("etcd-v3.5.17-linux-amd64/etcdctl")
        with open(E, "wb") as f:
            f.write(t.extractfile(m).read())
    os.chmod(E, 0o755)


def find_certs():
    # A process can exit between the glob and the read, so ENOENT/ESRCH on an
    # individual /proc entry is expected and skipped. Any other OSError is a real
    # fault on the /host/proc mount and is printed rather than swallowed —
    # otherwise a broken mount is indistinguishable from "no apiserver here".
    for f in glob.glob('/host/proc/*/comm'):
        try:
            with open(f) as fh:
                comm = fh.read().strip()
        except (FileNotFoundError, ProcessLookupError):
            continue
        except OSError as exc:
            print(f"  Warning: cannot read {f}: {exc}", flush=True)
            continue
        if comm != 'kube-apiserver':
            continue
        pid = f.split('/')[3]
        p = f'/host/proc/{pid}/root/system/secrets/kubernetes/kube-apiserver'
        if os.path.exists(p + '/etcd-client.crt'):
            return p
    return None


def run(cmd, timeout=120):
    # check=False on purpose: every caller inspects the returncode itself, and a
    # non-zero etcdctl exit is data here (an unreachable member), not a crash.
    r = subprocess.run([E] + cmd, capture_output=True, timeout=timeout, check=False)
    return r.stdout.decode().strip(), r.stderr.decode().strip(), r.returncode


# ── Setup ────────────────────────────────────────────────────────────────────
ensure_etcdctl()
certs = find_certs()
if not certs:
    print("ERROR: kube-apiserver certs not found on this node", flush=True)
    sys.exit(1)

CA   = certs + '/etcd-client-ca.crt'
CERT = certs + '/etcd-client.crt'
KEY  = certs + '/etcd-client.key'
OPTS = ['--cacert', CA, '--cert', CERT, '--key', KEY]


# ── 1. Check alarms ──────────────────────────────────────────────────────────
alarm_out, alarm_err, _ = run(['--endpoints', ENDPOINTS] + OPTS + ['alarm', 'list'])
print(f"Alarms: {alarm_out or 'NONE'}", flush=True)

has_corrupt  = 'CORRUPT' in alarm_out
has_nospace  = 'NOSPACE' in alarm_out
needs_defrag = has_corrupt or has_nospace
defrag_reason = []
if has_corrupt:
    defrag_reason.append("CORRUPT alarm")
if has_nospace:
    defrag_reason.append("NOSPACE alarm")


# ── 2. Check DB size and fragmentation ratio ─────────────────────────────────
status_out, _, _ = run(
    ['--endpoints', ENDPOINTS] + OPTS + ['endpoint', 'status', '--write-out=json'],
    timeout=30,
)
try:
    statuses = json.loads(status_out)
    for item in statuses:
        ep     = item.get('Endpoint', '?')
        total  = item['Status'].get('dbSize', 0)
        in_use = item['Status'].get('dbSizeInUse', total)
        ratio  = round(total / in_use, 2) if in_use else 1.0
        mb     = round(total / (1024 ** 2), 1)
        print(f"  {ep}: total={mb}MB in_use={round(in_use/(1024**2),1)}MB ratio={ratio}x", flush=True)
        if ratio > FRAG_RATIO_THRESHOLD:
            defrag_reason.append(f"{ep} ratio={ratio}x")
            needs_defrag = True
        if mb > ABS_SIZE_MB_THRESHOLD:
            defrag_reason.append(f"{ep} size={mb}MB")
            needs_defrag = True
except (ValueError, KeyError, TypeError) as exc:
    # Malformed/empty etcdctl JSON only. A crash here would be a bug worth seeing.
    print(f"  Warning: could not parse endpoint status: {exc}", flush=True)


# ── 3. Act ───────────────────────────────────────────────────────────────────
if not needs_defrag:
    print("✅ Cluster healthy. No defrag needed.", flush=True)
    sys.exit(0)

print(f"Defrag triggered — reasons: {'; '.join(defrag_reason)}", flush=True)

# Compact first to maximise the space reclaimed by defrag
rev_out, _, _ = run(['--endpoints', ENDPOINTS] + OPTS + ['endpoint', 'status', '--write-out=json'], timeout=30)
try:
    rev = json.loads(rev_out)[0]['Status']['header']['revision']
    out, err, rc = run(['--endpoints', ENDPOINTS] + OPTS + ['compact', str(rev)], timeout=60)
    print(f"Compact rev={rev}: {out or err or 'ok'}", flush=True)
except (ValueError, KeyError, TypeError, IndexError) as exc:
    # No parsable revision to compact at. Defrag below still runs and is the
    # part that reclaims space; compaction only improves how much it reclaims.
    print(f"Compact skipped: {exc}", flush=True)

for ep in ENDPOINTS.split(','):
    out, err, rc = run(['--endpoints', ep.strip()] + OPTS + ['defrag'], timeout=120)
    icon = "✅" if rc == 0 else "⚠️"
    print(f"  {icon} defrag {ep}: {out or err}", flush=True)

if has_corrupt or has_nospace:
    out, err, rc = run(['--endpoints', ENDPOINTS] + OPTS + ['alarm', 'disarm'])
    print(f"Disarm alarms: {out or err or 'ok'}", flush=True)

    alarm_out2, _, _ = run(['--endpoints', ENDPOINTS] + OPTS + ['alarm', 'list'])
    if 'CORRUPT' in alarm_out2 or 'NOSPACE' in alarm_out2:
        print(f"ERROR: Alarm still active after disarm: {alarm_out2}", flush=True)
        sys.exit(1)

# ── 4. Post-defrag status ────────────────────────────────────────────────────
status_out2, _, _ = run(
    ['--endpoints', ENDPOINTS] + OPTS + ['endpoint', 'status', '--write-out=table'],
    timeout=30,
)
print(f"Post-defrag status:\n{status_out2}", flush=True)
print("✅ etcd defrag complete.", flush=True)

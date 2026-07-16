#!/usr/bin/env python3
"""etcd health manager — runs inside a privileged pod that has /host/proc.

Actions (in order):
  1. Detect CORRUPT / NOSPACE alarms → compact + defrag + disarm
  2. Detect high fragmentation (ratio > 1.5x) or large DB (> 800 MB) → defrag
  3. Print a structured summary for GitHub Actions step output
"""
import subprocess
import glob
import sys
import os
import urllib.request
import tarfile
import io
import json

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
    t = tarfile.open(fileobj=io.BytesIO(data))
    m = t.getmember("etcd-v3.5.17-linux-amd64/etcdctl")
    with open(E, "wb") as f:
        f.write(t.extractfile(m).read())
    os.chmod(E, 0o755)


def find_certs():
    for f in glob.glob('/host/proc/*/comm'):
        try:
            if open(f).read().strip() == 'kube-apiserver':
                pid = f.split('/')[3]
                p = f'/host/proc/{pid}/root/system/secrets/kubernetes/kube-apiserver'
                if os.path.exists(p + '/etcd-client.crt'):
                    return p
        except Exception:
            pass
    return None


def run(cmd, timeout=120):
    r = subprocess.run([E] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
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
except Exception as exc:
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
except Exception as exc:
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

#!/usr/bin/env bash
# A bounded stress fixture catches whole-section shell pattern substitution on
# Linux too. It cannot establish macOS/BSD timings; the native release matrix
# exercises those. BASH32 may name an installed Bash 3.2 for explicit coverage.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$repo" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
shells = [shutil.which("bash")]
candidates = [os.environ.get("BASH32"), shutil.which("bash3.2"),
              shutil.which("bash32"), "/bin/bash", "/usr/local/bin/bash",
              "/opt/homebrew/bin/bash"]
found32 = False
for candidate in candidates:
    if not candidate or not os.access(candidate, os.X_OK):
        continue
    version = subprocess.check_output(
        [candidate, "-c", 'printf "%s" "$BASH_VERSION"'], text=True)
    if candidate == os.environ.get("BASH32") and not version.startswith("3.2."):
        raise SystemExit("FAIL: BASH32 must name Bash 3.2")
    if version.startswith("3.2."):
        found32 = True
        if candidate not in shells:
            shells.append(candidate)
if not found32:
    print("UNVERIFIED: Bash 3.2 unavailable; testing the installed Bash only", flush=True)

def bounded(argv):
    start = time.monotonic()
    # Kill the whole group on timeout, including any pipeline subprocesses.
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise SystemExit(f"FAIL: release notes exceeded 10s: {argv}")
        if process.returncode:
            raise SystemExit(f"FAIL: {argv}: {process.returncode}: {stderr!r}")
    print(f"ok: {argv[0]} {argv[-2:]} in {time.monotonic() - start:.3f}s", flush=True)
    return stdout

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "scripts").mkdir()
    script = root / "scripts/extract-release-notes.sh"
    shutil.copy2(repo / "scripts/extract-release-notes.sh", script)
    # Four MiB, thousands of long lines, with blank edges and a following
    # section: assert byte fidelity as well as bounded validation/extraction.
    body = (("- " + "release note " * 85 + "\n") * 4000).encode()
    (root / "CHANGELOG.md").write_bytes(
        b"## [1.2.3]\n\n" + body + b"\n\n## [1.2.2]\nold notes\n")
    for shell in shells:
        assert bounded([shell, str(script), "--check", "v1.2.3"]) == (
            b"release notes for 1.2.3: 4000 line(s)\n")
        assert bounded([shell, str(script), "v1.2.3"]) == body
print("PASS: large release notes remain bounded and byte-exact")
PY

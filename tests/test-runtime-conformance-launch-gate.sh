#!/usr/bin/env bash
# Structural integration contract for the default-off, shared launch quarantine.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = (root / 'bin/swarm-up.sh').read_text()
cli = (root / 'bin/swarm-runtime-conformance.ts').read_text()
app_server = (root / 'codex-bridge/app-server-stdio-transport.ts').read_text()
root_authority = (root / 'tests/test-harness-root-authority.sh').read_text()
start = source.index('_runtime_conformance_gate()')
launch = source.index('launch_one()', start)
helper = source[start:launch]
body_end = source.index('\n}', launch)
body = source[launch:body_end]

checks = {
    'gate defaults off without probing either runtime': 'SWARM_RUNTIME_CONFORMANCE_ENFORCE:-0' in helper
        and "0|'') return 0" in helper,
    'one common launch path gates the selected engine': body.count('_runtime_conformance_gate "$engine"') == 1,
    'native Claude cannot masquerade as the supervised print lane':
        'native interactive Claude is not a supervised lifecycle boundary' in helper
        and 'root harness claude -p lane' in helper,
    'Codex binds its preflight-attested executable': 'SWARM_CODEX_TRUSTED_BIN_REAL' in helper
        and 'SWARM_CODEX_ARGV_PREFIX' in helper,
    'ordinary default-off Claude launch retains its historical native command':
        'claude --dangerously-load-development-channels $PLUGIN$acct_rc --permission-mode auto' in body
        and 'SWARM_CONFORMED_CLAUDE_BIN_REAL' not in source,
    'gate runs before any tmux launch is created': body.index('_runtime_conformance_gate "$engine"')
        < body.index('tmux new-session'),
    'launch is check-only through the fixed no-argv root broker':
        '"operation":"conformance-check"' in helper
        and '["/usr/bin/sudo","-n","--",broker]' in helper
        and 'certifyRuntime' not in helper and '"$_helper"' not in helper,
    'mutable CLI exposes diagnostics but no certification command':
        "command: 'check' | 'diagnose'" in cli
        and 'check|diagnose' in cli and "command !== 'certify'" not in cli,
    'diagnostics refuse root execution of mutable test bytes':
        "process.geteuid?.() === 0" in cli
        and 'diagnose refuses root execution of mutable repository tests' in cli,
    'Codex admits only the already root-attested interpreter and argv prefix':
        'runtime != "codex" or path != expected_path or prefix != [expected_prefix]' in helper
        and 'runtime,swarm,expected_path,expected_prefix,broker=sys.argv[1:]' in helper,
    'root decision bytes are validated before shell newline normalization':
        'raw=result.stdout' in helper and 'raw != canonical' in helper,
    'root broker independently resolves swarm registration':
        '"swarm":swarm,"payload":{}' in helper and 'repo_root' not in helper,
    'diagnostic suite names the hardblocked Claude authority regression':
        'tests/test-harness-root-authority.sh' in cli
        and 'tests/test-claude-runtime-authority.py' in root_authority,
    'Claude certification remains restricted without a real exact-final reviewer':
        'restricted-no-attested-exact-final-reviewer' in cli
        and 'synthetic review-unavailable artifact' in cli
        and 'is not review evidence' in cli,
    'Codex app-server production wrapper pins the probed subcommand flags':
        "'app-server', '--listen', 'stdio://', '--strict-config'" in app_server,
}
failed = [label for label, passed in checks.items() if not passed]
for label in checks:
    print(('FAIL\t' if label in failed else 'OK\t') + label)
raise SystemExit(1 if failed else 0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "native Claude is restricted and Codex uses the root pre-tmux quarantine"
else
  bad "shared launch quarantine structural contract"
fi

if grep -q 'swarm-restart.sh' "$ROOT/bin/swarm-account.sh" \
   && grep -q 'swarm-up.sh up' "$ROOT/bin/swarm-restart.sh"; then
  ok "Claude account rotation re-enters through the gated launch path"
else
  bad "Claude account rotation no longer re-enters through swarm-up"
fi

if [ "$FAIL" -eq 0 ]; then
  printf '  ALL PASS\n'
  exit 0
fi
printf '  FAILURES: %s\n' "$FAIL" >&2
exit 1

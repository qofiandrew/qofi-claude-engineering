#!/usr/bin/env bash
# test-cpo-bus-binding.sh — the CPO gets operator+bus; every CTO stays single-bound.
#
# Exercises swarm_bound_exports (swarm-lib.sh), the single source that derives a
# swarm's Discord binding at launch. The INVARIANT under test: only the CPO swarm
# is bound to the bus; a CTO swarm's binding is exactly its own channel and it
# gets no operator/bus role env. bash 3.2-safe.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../bin/swarm-lib.sh"

BUS=1510301812434141194
OP=1508921858165047390          # #qofi-product
CTO=1507159618453770291         # a CTO's own channel

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
has()  { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

echo "=== CPO swarm (qofi-product): bound to operator+bus, with role env ==="
CPO_OUT="$(swarm_bound_exports qofi-product "$OP")"
has "DISCORD_BOUND_CHANNEL='$OP,$BUS'" "$CPO_OUT" && ok "CPO bound to union operator,bus" || no "CPO union bind ($CPO_OUT)"
has "DISCORD_OPERATOR_CHANNEL='$OP'"   "$CPO_OUT" && ok "CPO has DISCORD_OPERATOR_CHANNEL" || no "CPO operator role env"
has "DISCORD_BUS_CHANNEL='$BUS'"       "$CPO_OUT" && ok "CPO has DISCORD_BUS_CHANNEL" || no "CPO bus role env"

echo ""
echo "=== CTO swarm (INVARIANT): single-bound to own channel, NO bus, NO role env ==="
CTO_OUT="$(swarm_bound_exports reserve-backend-2 "$CTO")"
[ "$CTO_OUT" = "export DISCORD_BOUND_CHANNEL='$CTO'" ] && ok "CTO bound to ONLY its own channel" || no "CTO binding not exactly own channel ($CTO_OUT)"
has "$BUS" "$CTO_OUT"                  && no "CTO leaked the bus id!" || ok "CTO has NO bus id"
has "DISCORD_BUS_CHANNEL" "$CTO_OUT"   && no "CTO got DISCORD_BUS_CHANNEL!" || ok "CTO has NO DISCORD_BUS_CHANNEL"
has "DISCORD_OPERATOR_CHANNEL" "$CTO_OUT" && no "CTO got DISCORD_OPERATOR_CHANNEL!" || ok "CTO has NO DISCORD_OPERATOR_CHANNEL"

echo ""
echo "=== legacy empty channel → empty single bind (unchanged) ==="
EMPTY_OUT="$(swarm_bound_exports some-legacy "")"
[ "$EMPTY_OUT" = "export DISCORD_BOUND_CHANNEL=''" ] && ok "empty channel → empty bind" || no "empty-channel handling ($EMPTY_OUT)"

echo ""
echo "=== a swarm NAMED like the operator id but not the CPO name stays single-bound ==="
OTHER_OUT="$(swarm_bound_exports press-backend 1510131439906066442)"
has "$BUS" "$OTHER_OUT" && no "non-CPO swarm got the bus!" || ok "another CTO stays bus-free"

echo ""
echo "=== overrides honored (SWARM_CPO_NAME / SWARM_BUS_CHANNEL) ==="
OV_OUT="$(SWARM_CPO_NAME=acme-cpo SWARM_BUS_CHANNEL=222 swarm_bound_exports acme-cpo 111)"
has "DISCORD_BOUND_CHANNEL='111,222'" "$OV_OUT" && ok "override CPO name + bus id" || no "override ($OV_OUT)"
# and the real CPO name is NOT special when overridden away
OV2="$(SWARM_CPO_NAME=acme-cpo swarm_bound_exports qofi-product "$OP")"
has "$BUS" "$OV2" && no "qofi-product still got bus after override!" || ok "override re-points CPO detection"

echo ""
echo "=== explicit archetype keeps Codex CPO binding independent of deployment name ==="
TYPE_OUT="$(swarm_bound_exports product-vision 333 cpo)"
has "DISCORD_OPERATOR_CHANNEL='333'" "$TYPE_OUT" && ok "type=cpo binds its operator channel" || no "type=cpo operator role missing"
has "DISCORD_BUS_CHANNEL='$BUS'" "$TYPE_OUT" && ok "type=cpo binds the bus regardless of name" || no "type=cpo bus role missing"

echo ""
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# Build and run the IncomeRouter's suite (test/income; docs/proposals/2026-11-01-income-repay-and-inference-on-credit.md
# section 5) in a scratch project that holds only src/IncomeRouter.sol, src/AutoRepayV2.sol (the window it reuses, and a
# repayment that beats the router), their mocks, the suite, the deploy script and CreditPoolV2's build artifact:
# nothing compiles the pool's source (it is deployed from out/, PoolV2Lib linked by test/protocol/PoolArtifact.sol),
# and the repository is never compiled whole. As test/autopay2/forge.sh.
#
#   bash test/income/forge.sh test -vv                                         # unit, fuzz, invariants
#   FORK_RPC=https://rpc.mainnet.chain.robinhood.com bash test/income/forge.sh test --match-contract Fork -vv
#   bash test/income/forge.sh coverage --report summary --no-match-contract Fork
#   bash test/income/forge.sh script script/DeployIncomeRouter.s.sol --rpc-url http://127.0.0.1:8545   # a fork's dry run
#
# Scratch dir: $INCOME_DIR or ${TMPDIR:-/tmp}/priors-income. CreditPoolV2's artifact comes from out/ (this checkout's,
# else the main checkout's): run `forge build src/CreditPoolV2.sol` there first if it is missing.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D="${INCOME_DIR:-${TMPDIR:-/tmp}/priors-income}"
MAIN="${ROOT%%/.claude/worktrees/*}"
# a worktree anywhere else (a scratch folder, its submodules not checked out): the main checkout is the one whose .git
# it shares
if [ "$MAIN" = "$ROOT" ] && GCD="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  MAIN="${GCD%/.git}"
fi
OUTROOT="$ROOT/out"; [ -f "$OUTROOT/PoolV2Lib.sol/PoolV2Lib.pool-v2.json" ] || OUTROOT="$MAIN/out"
LIBROOT="$ROOT/lib"; [ -f "$LIBROOT/forge-std/src/Test.sol" ] || LIBROOT="$MAIN/lib"
ART="$OUTROOT/CreditPoolV2.sol/CreditPoolV2.json"
LIB="$OUTROOT/PoolV2Lib.sol/PoolV2Lib.pool-v2.json"
for a in "$ART" "$LIB"; do
  [ -f "$a" ] || { echo "missing $a: run 'forge build src/CreditPoolV2.sol' in the repository first" >&2; exit 1; }
done

rm -rf "$D/src" "$D/test" "$D/script"
mkdir -p "$D/src/mocks" "$D/test/income" "$D/test/protocol" "$D/script" "$D/lib" "$D/out/CreditPoolV2.sol" \
  "$D/out/PoolV2Lib.sol" "$D/deployments"
cp -p "$ROOT/src/IncomeRouter.sol" "$ROOT/src/AutoRepayV2.sol" "$D/src/"
cp -p "$ROOT/src/mocks/MockIdentityRegistry.sol" "$D/src/mocks/"
cp -p "$ROOT"/test/income/*.sol "$D/test/income/"
cp -p "$ROOT/test/protocol/PoolArtifact.sol" "$D/test/protocol/"
cp -p "$ROOT/script/DeployIncomeRouter.s.sol" "$D/script/"
cp -p "$ROOT/deployments/4663.v2.json" "$D/deployments/"
cp -p "$ART" "$D/out/CreditPoolV2.sol/"
cp -p "$LIB" "$D/out/PoolV2Lib.sol/"
rm -f "$D/lib/forge-std" "$D/lib/openzeppelin-contracts"
ln -s "$LIBROOT/forge-std" "$D/lib/forge-std"
ln -s "$LIBROOT/openzeppelin-contracts" "$D/lib/openzeppelin-contracts"
cp -p "$ROOT/remappings.txt" "$D/"
cat > "$D/foundry.toml" <<'TOML'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = false
fs_permissions = [{ access = "read", path = "./out" }, { access = "read-write", path = "./deployments" }]

[rpc_endpoints]
robinhood = "https://rpc.mainnet.chain.robinhood.com"

[fuzz]
runs = 256

[invariant]
runs = 64
depth = 200
fail_on_revert = false
TOML
cd "$D"
forge "$@"

#!/usr/bin/env bash
# Fail if this repo is not safe to be public.
#
#   bash scripts/check-public.sh           tracked files only (fast; this is what CI runs)
#   bash scripts/check-public.sh --history every blob in every commit, too
#
# Two independent checks, because they catch different mistakes:
#
#   1. Shape matching for credentials. A checker that hardcodes the literal secrets it hunts for is itself the
#      leak, so this matches the *shape* of a key being assigned to a key-shaped name. `$PRIVATE_KEY`
#      references and the `0x` placeholder in .env.example correctly do not match.
#   2. An inventory rule. This repo is the public half of a larger private one; the failure that actually
#      matters is a file being copied across that was never meant to ship.
#
# Exit 0 clean, 1 if anything is found.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
history=0
[ "${1:-}" = "--history" ] && history=1

say_ok()   { echo "  ok: $1"; }
say_bad()  { echo "LEAK: $1"; fail=1; }

# ---------------------------------------------------------------- 1. credential shapes
# Each entry is a credential this project actually handles. A private key and a transaction hash are both
# 0x + 64 hex and cannot be told apart by shape, so a bare shape rule would fire on every legitimate tx hash and
# teach everyone to ignore it. The rules below match assignment, which is what a real leak looks like.
# ⛔ ONE list, used by BOTH the tracked-file scan and the history scan below. When they were two lists, the
# history expression silently omitted the OpenAI and AWS patterns, so a key committed and later deleted passed
# `--history` clean while remaining permanently retrievable from a public repo. A partial scan that prints "ok"
# is worse than no scan.
CRED_LABELS=(
  "assigned EVM private key"
  "assigned hex mnemonic"
  "Cloudflare API token"
  "Anthropic API key"
  "OpenAI API key"
  "GitHub token"
  "AWS access key id"
  "private key PEM block"
)
CRED_PATTERNS=(
  '(PRIVATE_KEY|privateKey|private_key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?(0x)?[a-fA-F0-9]{64}'
  '(MNEMONIC|mnemonic)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?(0x)?[a-fA-F0-9]{64}'
  'cfat_[A-Za-z0-9_-]{20,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-(proj-)?[A-Za-z0-9_-]{32,}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'AKIA[0-9A-Z]{16}'
  'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY'
)

shape() {  # shape <label> <extended-regex>
  local label="$1" re="$2" hits
  hits=$(git ls-files -z | xargs -0 grep -lIE -- "$re" 2>/dev/null)
  if [ -n "$hits" ]; then
    say_bad "$label is present in:"
    echo "$hits" | sed 's/^/    /'
  else
    say_ok "no $label in tracked files"
  fi
}

for i in "${!CRED_PATTERNS[@]}"; do
  shape "${CRED_LABELS[$i]}" "${CRED_PATTERNS[$i]}"
done

# The one word mnemonic that is allowed here: anvil's own published test phrase, used only on chain 31337.
# Any *other* 12-or-more-word BIP-39-looking phrase assigned to a mnemonic variable is a real finding.
if git ls-files -z | xargs -0 grep -hIE '(MNEMONIC|mnemonic)[^=:]*[:=][^"'"'"']*["'"'"']([a-z]+ ){11,}[a-z]+' 2>/dev/null \
   | grep -qvF "test test test test test test test test test test test junk"; then
  say_bad "a word mnemonic other than anvil's public test phrase is assigned in a tracked file"
else
  say_ok "no non-public word mnemonic assigned in tracked files"
fi

# ---------------------------------------------------------------- 2. inventory
# Paths that must never be tracked here, whatever .gitignore currently says. `.gitignore` protects against
# accident; this protects against `git add -f` and against a future edit to .gitignore.
forbidden=(
  ".env"
  "cloudflare"
  "wallet.json"
  "deployments/31337.json"
  "docs/plans"    # agent working state: plans, buildouts and session notes are not the product
  "docs/builds"
  "docs/prd"
  "docs/reports"
  ".annotations"
  ".pilot"
  ".claude"
  "CLAUDE.md"
  "web"          # the site lives in the private repo and must not be published from here
  "sim"
  "api"
  "brand"
  "dist"
  "node_modules"
  ".wrangler"
)
for path in "${forbidden[@]}"; do
  if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || [ -n "$(git ls-files -- "$path/" 2>/dev/null)" ]; then
    say_bad "'$path' is tracked and must not be in a public repo"
  fi
done
say_ok "no forbidden path is tracked"

# Every tracked top-level entry must be one this repo declares. A new one is not automatically wrong — it is
# something a human has to look at before it goes public.
allowed_top="AGENTS.md README.md LICENSE SECURITY.md BOUNTY.md package.json package-lock.json foundry.toml remappings.txt .env.example .gitignore .gitmodules .github bin deployments docs lib packages script scripts sdk skills src test"
while read -r entry; do
  [ -z "$entry" ] && continue
  case " $allowed_top " in
    *" $entry "*) ;;
    *) say_bad "undeclared top-level entry '$entry' — add it to allowed_top in this script once you have checked it is publishable" ;;
  esac
done < <(git ls-files | cut -d/ -f1 | sort -u)
say_ok "every tracked top-level entry is declared"

# ---------------------------------------------------------------- 3. history (opt-in)
# A secret removed in a later commit is still public once the repo is. Scans every blob that ever existed.
if [ "$history" -eq 1 ]; then
  echo "  .. scanning every blob in history against all ${#CRED_PATTERNS[@]} credential patterns"
  # Built from the same array as the tracked-file scan, so the two can never drift apart again.
  history_re=$(IFS='|'; echo "${CRED_PATTERNS[*]}")
  hits=$(git rev-list --objects --all 2>/dev/null | awk '{print $1}' | \
    while read -r obj; do
      [ "$(git cat-file -t "$obj" 2>/dev/null)" = "blob" ] || continue
      if git cat-file -p "$obj" 2>/dev/null | grep -qIE "$history_re"; then
        echo "$obj"
      fi
    done)
  if [ -n "$hits" ]; then
    say_bad "credential-shaped content in historical blob(s):"
    echo "$hits" | sed 's/^/    /'
  else
    say_ok "no credential-shaped content anywhere in history"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "clean: safe to publish"; else echo "FAILED: do not publish"; fi
exit "$fail"

#!/usr/bin/env bash
#
# Verify the whole Karabiner-Elements chain and name the exact broken link.
#
# Karabiner fails silently: a wrong permission or an unwritable configuration
# directory produces no visible symptom beyond keys simply not being remapped,
# and the two failures look identical from the outside. On 2026-08-13 that cost
# hours — Accessibility was already granted, but an unwritable configuration
# directory (a Home Manager symlink into the read-only Nix store) blocked the
# agent before it could ever act on the grant, so every symptom pointed at
# permissions. This script distinguishes them.

set -uo pipefail

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); RESET=$(tput sgr0)
  GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

failures=0
pass() { printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n       %s→ %s%s\n' "$RED" "$RESET" "$1" "$YELLOW" "$2" "$RESET"; failures=$((failures + 1)); }

CORE_SERVICE="/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app"
CONFIG_DIR="$HOME/.config/karabiner"

printf '%sKarabiner-Elements health%s\n' "$BOLD" "$RESET"

# 1. Application present.
if [[ -d /Applications/Karabiner-Elements.app ]]; then
  pass "application installed"
else
  fail "application missing" "declared as a Homebrew cask; run darwin-rebuild switch"
fi

# 2. DriverKit extension approved. Without this nothing can be intercepted.
if systemextensionsctl list 2>/dev/null | grep -q "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.*activated enabled"; then
  pass "driver extension activated"
else
  fail "driver extension not activated" \
       "System Settings > General > Login Items & Extensions > Driver Extensions"
fi

# 3. Configuration directory must be REAL and WRITABLE. Karabiner rewrites
#    karabiner.json (selected profile, GUI edits) and refuses a directory it
#    cannot write. A Nix store symlink here fails and is the trap this exists for.
if [[ -L "$CONFIG_DIR" ]]; then
  fail "config directory is a symlink (likely into the Nix store)" \
       "modules/home/karabiner.nix must install a real file, not home.file"
elif [[ ! -d "$CONFIG_DIR" ]]; then
  fail "config directory missing" "run darwin-rebuild switch"
elif ! touch "$CONFIG_DIR/.writecheck" 2>/dev/null; then
  fail "config directory not writable" \
       "Karabiner logs 'permissions failed: Operation not permitted' and never loads rules"
else
  rm -f "$CONFIG_DIR/.writecheck"
  pass "config directory is real and writable"
fi

# 4. Configuration parses and carries the declared rules.
if [[ -f "$CONFIG_DIR/karabiner.json" ]] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CONFIG_DIR/karabiner.json" 2>/dev/null; then
  rules=$(python3 -c "
import json
d = json.load(open('$CONFIG_DIR/karabiner.json'))
print(len(d['profiles'][0]['complex_modifications']['rules']))" 2>/dev/null || echo 0)
  pass "karabiner.json valid ($rules complex rules)"
else
  fail "karabiner.json missing or invalid" "run darwin-rebuild switch"
fi

# 5. Accessibility must be granted to Karabiner-Core-Service — NOT to
#    Karabiner-Elements.app, which is only the settings window. Granting the
#    wrong one looks correct in System Settings and changes nothing.
if pgrep -f "Karabiner-Core-Service" >/dev/null 2>&1; then
  pass "core service running"
else
  fail "core service not running" "launch Karabiner-Elements once to start its background services"
fi

# 6. The definitive check: is the keyboard actually grabbed?
log=/var/log/karabiner/core_service.log
if [[ -r "$log" ]] && tail -50 "$log" 2>/dev/null | grep -q "hid queue value monitor is started (grabbed)"; then
  pass "keyboard grabbed — remapping is live"
elif [[ -r "$log" ]] && tail -50 "$log" 2>/dev/null | grep -q "required permissions are not granted"; then
  fail "device_grabber not started — permissions" \
       "grant Accessibility to $CORE_SERVICE (NOT Karabiner-Elements.app)"
else
  fail "cannot confirm keyboard is grabbed" "check $log"
fi

echo
if (( failures == 0 )); then
  printf '%s%sAll checks passed.%s Tap Escape: it should type a backtick.\n' "$BOLD" "$GREEN" "$RESET"
else
  printf '%s%s%d check(s) failed.%s Fix the first failure above and re-run.\n' "$BOLD" "$RED" "$failures" "$RESET"
fi
exit $(( failures > 0 ))

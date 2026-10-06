#!/usr/bin/env python3
"""Regress the official Nix installer -> nix-darwin shell-file handoff.

Only public, stock shell contents are used; never read the host's /etc files.
Sources:
- apple-oss-distributions/bash@51bf3fc6f26e9517c3a2e4bc3d208f9b39b87178/bashrc
- apple-oss-distributions/zsh@666e91a595af505ef61d5f9b87df7a014a4937c6/zshrc
- NixOS/nix@a408bc3e30e3e5b7ff61596d1072973679761363/scripts/install-multi-user.sh
Stock/appended checksums below come from the bash/zsh modules in
nix-darwin@c3e90c89649b07d1a96e4b9dd6cd0d6e44b91a74.
"""

import hashlib
from pathlib import Path
import re
import sys
import unittest

MODULE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1] / "modules/darwin/default.nix"
)

# Includes the leading and trailing blank lines emitted by shell_source_lines().
HOOK = b"""
# Nix
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi
# End Nix

"""

BASHRC = rb"""# System-wide .bashrc file for interactive bash(1) shells.
if [ -z "$PS1" ]; then
   return
fi

PS1='\h:\W \u\$ '
# Make bash check its window size after a process completes
shopt -s checkwinsize

[ -r "/etc/bashrc_$TERM_PROGRAM" ] && . "/etc/bashrc_$TERM_PROGRAM"
"""

ZSHRC = rb"""# System-wide profile for interactive zsh(1) shells.

# Setup user specific overrides for this in ~/.zshrc. See zshbuiltins(1)
# and zshoptions(1) for more details.

# Correctly display UTF-8 with combining characters.  We'll assume UTF-8 if the
# locale(1) binary is missing entirely.
if [[ ! -x /usr/bin/locale ]] || [[ "$(locale LC_CTYPE)" == "UTF-8" ]]; then
    setopt COMBINING_CHARS
fi

# Disable the log builtin, so we don't conflict with /usr/bin/log
disable log

# Save command history
HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
HISTSIZE=2000
SAVEHIST=1000

# Beep on error
setopt BEEP

# Use keycodes (generated via zkbd) if present, otherwise fallback on
# values from terminfo
if [[ -r ${ZDOTDIR:-$HOME}/.zkbd/${TERM}-${VENDOR} ]] ; then
    source ${ZDOTDIR:-$HOME}/.zkbd/${TERM}-${VENDOR}
else
    typeset -g -A key

    [[ -n "$terminfo[kf1]" ]] && key[F1]=$terminfo[kf1]
    [[ -n "$terminfo[kf2]" ]] && key[F2]=$terminfo[kf2]
    [[ -n "$terminfo[kf3]" ]] && key[F3]=$terminfo[kf3]
    [[ -n "$terminfo[kf4]" ]] && key[F4]=$terminfo[kf4]
    [[ -n "$terminfo[kf5]" ]] && key[F5]=$terminfo[kf5]
    [[ -n "$terminfo[kf6]" ]] && key[F6]=$terminfo[kf6]
    [[ -n "$terminfo[kf7]" ]] && key[F7]=$terminfo[kf7]
    [[ -n "$terminfo[kf8]" ]] && key[F8]=$terminfo[kf8]
    [[ -n "$terminfo[kf9]" ]] && key[F9]=$terminfo[kf9]
    [[ -n "$terminfo[kf10]" ]] && key[F10]=$terminfo[kf10]
    [[ -n "$terminfo[kf11]" ]] && key[F11]=$terminfo[kf11]
    [[ -n "$terminfo[kf12]" ]] && key[F12]=$terminfo[kf12]
    [[ -n "$terminfo[kf13]" ]] && key[F13]=$terminfo[kf13]
    [[ -n "$terminfo[kf14]" ]] && key[F14]=$terminfo[kf14]
    [[ -n "$terminfo[kf15]" ]] && key[F15]=$terminfo[kf15]
    [[ -n "$terminfo[kf16]" ]] && key[F16]=$terminfo[kf16]
    [[ -n "$terminfo[kf17]" ]] && key[F17]=$terminfo[kf17]
    [[ -n "$terminfo[kf18]" ]] && key[F18]=$terminfo[kf18]
    [[ -n "$terminfo[kf19]" ]] && key[F19]=$terminfo[kf19]
    [[ -n "$terminfo[kf20]" ]] && key[F20]=$terminfo[kf20]
    [[ -n "$terminfo[kbs]" ]] && key[Backspace]=$terminfo[kbs]
    [[ -n "$terminfo[kich1]" ]] && key[Insert]=$terminfo[kich1]
    [[ -n "$terminfo[kdch1]" ]] && key[Delete]=$terminfo[kdch1]
    [[ -n "$terminfo[khome]" ]] && key[Home]=$terminfo[khome]
    [[ -n "$terminfo[kend]" ]] && key[End]=$terminfo[kend]
    [[ -n "$terminfo[kpp]" ]] && key[PageUp]=$terminfo[kpp]
    [[ -n "$terminfo[knp]" ]] && key[PageDown]=$terminfo[knp]
    [[ -n "$terminfo[kcuu1]" ]] && key[Up]=$terminfo[kcuu1]
    [[ -n "$terminfo[kcub1]" ]] && key[Left]=$terminfo[kcub1]
    [[ -n "$terminfo[kcud1]" ]] && key[Down]=$terminfo[kcud1]
    [[ -n "$terminfo[kcuf1]" ]] && key[Right]=$terminfo[kcuf1]
fi

# Default key bindings
[[ -n ${key[Delete]} ]] && bindkey "${key[Delete]}" delete-char
[[ -n ${key[Home]} ]] && bindkey "${key[Home]}" beginning-of-line
[[ -n ${key[End]} ]] && bindkey "${key[End]}" end-of-line
[[ -n ${key[Up]} ]] && bindkey "${key[Up]}" up-line-or-search
[[ -n ${key[Down]} ]] && bindkey "${key[Down]}" down-line-or-search

# Default prompt
PS1="%n@%m %1~ %# "

# Useful support for interacting with Terminal.app or other terminal programs
[ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"
"""

FIXTURES = (
    ("bashrc", BASHRC,
     "444c716ac2ccd9e1e3347858cb08a00d2ea38e8c12fdc5798380dc261e32e9ef",
     "617b39e36fa69270ddbee19ddc072497dbe7ead840cbd442d9f7c22924f116f4"),
    ("zshrc", ZSHRC,
     "4d1ab5704f9d167a042fecac0d056c8a79a8ebd71e032d3489536c8db9ffe3e0",
     "bf76c5ed8e65e616f4329eccf662ee91be33b8bfd33713ce9946f2fe94fea7fa"),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ShellBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = MODULE.read_text()
        cls.allowed = {}
        for name in ("bashrc", "zshrc"):
            match = re.search(
                r'environment\.etc\."' + name + r'"\.knownSha256Hashes\s*=\s*\[(.*?)\];',
                text, re.S,
            )
            if match is None:
                raise AssertionError(f"Missing knownSha256Hashes for {name}")
            cls.allowed[name] = set(re.findall(r'"([0-9a-f]{64})"', match.group(1)))

    def test_stock_fixtures_match_upstream(self):
        for name, base, stock_hash, _ in FIXTURES:
            with self.subTest(name=name, stock=stock_hash):
                self.assertEqual(digest(base), stock_hash)

    def test_legacy_installer_matches_upstream(self):
        for name, base, _, appended_hash in FIXTURES:
            with self.subTest(name=name, appended=appended_hash):
                self.assertEqual(digest(base + HOOK), appended_hash)

    def test_only_exact_prepended_variants_are_added(self):
        for name, actual in self.allowed.items():
            expected = {digest(HOOK + base) for shell, base, _, _ in FIXTURES if shell == name}
            self.assertEqual(actual, expected)

    def test_custom_content_is_not_recognized(self):
        for name, base, stock_hash, appended_hash in FIXTURES:
            with self.subTest(name=name, stock=stock_hash):
                allowed = self.allowed[name] | {stock_hash, appended_hash}
                custom = b"export COMPANY_SHELL_POLICY=enabled\n"
                self.assertNotIn(digest(HOOK + base + custom), allowed)
                self.assertNotIn(digest(custom + HOOK + base), allowed)
                self.assertNotIn(digest(HOOK + base.replace(b"PS1=", b"CUSTOM_PS1=")), allowed)


if __name__ == "__main__":
    unittest.main(verbosity=2)

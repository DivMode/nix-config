#!/bin/sh
#
# SUDO_ASKPASS helper: prompt for the account password in a native macOS dialog.
#
# `sudo` normally reads the password from a controlling terminal. Automated and
# editor-hosted shells have no TTY, so sudo aborts with "a terminal is required
# to read the password". sudo's documented answer is an askpass helper: with
# `sudo -A`, it executes this program and reads the password from stdout.
#
# The password is passed straight to sudo through that pipe. It is never
# written to disk, never placed in a command line where `ps` could show it, and
# never stored by this script.

exec /usr/bin/osascript \
  -e 'display dialog "darwin-rebuild needs your macOS account password to activate the Nix configuration." with title "Activate Nix configuration" default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue"' \
  -e 'text returned of result'

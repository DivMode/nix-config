# `claude-goal`: the session goal's managed Stop hook (`claude-goal hook`,
# declared in ai/hooks/default.nix) and its command line, one Rust binary so
# the two cannot disagree. `cargo test` runs in the build: the blocking rules
# are checked every time the binary is.
{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "claude-goal";
  version = "0.1.0";
  src = ./goal;
  cargoLock.lockFile = ./goal/Cargo.lock;
  meta.mainProgram = "claude-goal";
}

# homebrew-pinned

An in-repo Homebrew tap for casks this configuration deliberately holds at a
version the upstream `homebrew/homebrew-cask` pin does not carry. It is wired
into `nix-homebrew` by `modules/darwin/homebrew.nix`, which is also where each
pinned cask's declaration documents WHY it is pinned and what unpinning takes.

Rules for a cask in here:

- The header comment states its provenance: either the exact upstream
  homebrew-cask revision it was vendored from, or that it was written here and
  from what upstream facts.
- The `url` must name an exact version and the `sha256` must be real — a pin
  whose bytes can drift is not a pin.
- Every entry is temporary in spirit. When the reason for the pin passes,
  restore the plain upstream token in `modules/darwin/homebrew.nix` and delete
  the file here.

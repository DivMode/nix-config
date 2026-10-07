# Python: uv is its only owner. `python3`/`python` and `pip3`/`pip` on PATH
# resolve through uv, uv never selects a system interpreter, and the global
# pin applies where a project has no `.python-version`. Projects pin their
# own version there; see the global agent policy (ai/instructions/global.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # `python3` and `python` on PATH. uv owns Python interpreters (see
  # development.md, "Runtime ownership"), but nothing put one on PATH, so bare `python3` fell
  # through to macOS's /usr/bin/python3 — 3.9.6, which broke a tool needing
  # 3.10+ on 2026-10-03. This resolves the interpreter uv would choose here:
  # the nearest project `.python-version`, else the global pin in
  # `pythonDefault` below, never a system Python (`only-managed`). A version
  # not yet installed is downloaded on first use, the way mise supplies Node,
  # rather than during activation. `--system` skips virtualenvs: an activated
  # one is already ahead of this on PATH, and an unactivated `.venv` should not
  # be entered implicitly. uv is called by store path so the interpreter's
  # environment is not changed.
  #
  # `--managed-python` is required, not belt and braces. uv lists this launcher
  # itself as a system interpreter, and `only-managed` is only a user-level
  # default: a project's `[tool.uv] python-preference = "system"` or
  # UV_PYTHON_PREFERENCE overrides it. uv then picks or queries the launcher,
  # which runs uv, which runs the launcher. Found in independent review
  # 2026-10-03. A bounded repro never printed and was killed at 4 s (rc 137),
  # and an unbounded run exhausted the per-user process limit. The flag holds
  # whatever a project prefers. uv refuses the flag alongside
  # UV_PYTHON_PREFERENCE or UV_NO_MANAGED_PYTHON (exit 2, measured), so those
  # are cleared for the launcher's own lookups only. The interpreter it execs
  # keeps the caller's environment.
  pythonLauncher = pkgs.writeShellApplication {
    name = "python3";
    text = ''
      uv() {
        env -u UV_PYTHON_PREFERENCE -u UV_NO_MANAGED_PYTHON \
          ${lib.getExe config.programs.uv.package} "$@"
      }
      if ! interpreter="$(uv python find --managed-python --system 2>/dev/null)"; then
        uv python install --managed-python >&2
        interpreter="$(uv python find --managed-python --system)"
      fi
      exec "$interpreter" "$@"
    '';
  };

  # `pip3` and `pip` are the pip of that same interpreter. Without them, bare
  # `pip3` fell through to macOS's /usr/bin/pip3 and installed into Apple's
  # Python 3.9 while `python3` ran uv's, so the package silently landed in a
  # different interpreter (a project recipe on 2026-10-06 did
  # `pip3 install --break-system-packages` and its import still failed). uv
  # marks its interpreters EXTERNALLY-MANAGED, so `pip3 install` now refuses
  # loudly ("This Python installation is managed by uv", measured) and points
  # at a venv or `uv run --with`.
  pipLauncher = pkgs.writeShellApplication {
    name = "pip3";
    text = ''exec ${lib.getExe pythonLauncher} -m pip "$@"'';
  };

  python = pkgs.runCommand "python-launcher" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getExe pythonLauncher} $out/bin/python3
    ln -s ${lib.getExe pythonLauncher} $out/bin/python
    ln -s ${lib.getExe pipLauncher} $out/bin/pip3
    ln -s ${lib.getExe pipLauncher} $out/bin/pip
  '';

  # The machine-wide default minor version: the newest stable CPython uv
  # offers (3.14.6 on 2026-10-03; uv 0.11.21 lists no 3.15 build). uv takes
  # the latest patch of it. Projects pin their own in `.python-version`.
  pythonDefault = "3.14";
in
{
  home.packages = [ python ];

  # uv itself, and ~/.config/uv/uv.toml. `only-managed` keeps uv from ever
  # selecting macOS's Python 3.9 or another system interpreter. uv never
  # writes uv.toml, so a store symlink is safe.
  programs.uv = {
    enable = true;
    settings.python-preference = "only-managed";
  };

  # The global pin uv reads when no project pins a version. Read-only on
  # purpose: `uv python pin --global` would fail here; change `pythonDefault`.
  xdg.configFile."uv/.python-version".text = "${pythonDefault}\n";
}

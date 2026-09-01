{ lib, pkgs, ... }:
let
  karabinerConfiguration = {
    # Karabiner-Menu is a separate menu-bar process. Its visibility is part of
    # the declarative configuration, so it belongs here rather than in any
    # application UI state. Karabiner defaults both of these to true when the
    # `global` section is absent, which is why the icon appeared.
    global = {
      show_in_menu_bar = false;
      show_profile_name_in_menu_bar = false;

      # Karabiner must not offer its own updates. Versions here arrive as a
      # homebrew-cask lock bump reviewed in git, so an in-app "a new version is
      # available" notice can only advertise a version this repository has not
      # adopted, and accepting it would install software no commit describes.
      # The key is Karabiner's own (`check_for_updates_on_startup`, present in
      # the 16.x Karabiner-Elements binary); it suppresses the check, not just
      # the notification.
      check_for_updates_on_startup = false;
    };

    profiles = [
      {
        name = "Default";
        selected = true;
        virtual_hid_keyboard.keyboard_type_v2 = "ansi";

        # Preserve the recovered physical-Escape behavior. Caps Lock remains
        # the universally available Escape key through the complex rule below.
        simple_modifications = [
          {
            from.key_code = "escape";
            to = [ { key_code = "grave_accent_and_tilde"; } ];
          }
        ];

        # Logitech keyboards own their top-row mode. Karabiner documents that
        # this must remain empty for Logitech-specific Fn keys to work.
        fn_function_keys = [ ];

        complex_modifications.rules = [
          {
            description = "Use Hyper+I/J/K/L as arrow keys";
            manipulators =
              map
                (mapping: {
                  type = "basic";
                  from = {
                    key_code = mapping.from;
                    modifiers.mandatory = [
                      "left_command"
                      "left_control"
                      "left_option"
                      "left_shift"
                    ];
                  };
                  to = [ { key_code = mapping.to; } ];
                })
                [
                  {
                    from = "i";
                    to = "up_arrow";
                  }
                  {
                    from = "j";
                    to = "left_arrow";
                  }
                  {
                    from = "k";
                    to = "down_arrow";
                  }
                  {
                    from = "l";
                    to = "right_arrow";
                  }
                ];
          }
          {
            # Caps Lock held is Hyper (see the rule below), so this is the
            # "Caps Lock and Space" launcher. Space is deliberately reused:
            # Command-Space belongs to Raycast and Spotlight's shortcuts 64/65
            # are disabled in launchers.nix, so nothing else claims it.
            # `open` focuses an existing instance instead of starting a second
            # one. Karabiner runs shell_command with a minimal PATH, so the
            # absolute binary path is required. `-b` addresses Ghostty by
            # bundle identifier rather than by path: Home Manager places the
            # bundle under `~/Applications/Home Manager Apps/`, a path
            # containing spaces that would have to be quoted inside this JSON
            # string, and the identifier is stable wherever the copy lands.
            description = "Use Hyper+Space to open Ghostty";
            manipulators = [
              {
                type = "basic";
                from = {
                  key_code = "spacebar";
                  modifiers.mandatory = [
                    "left_command"
                    "left_control"
                    "left_option"
                    "left_shift"
                  ];
                };
                to = [ { shell_command = "/usr/bin/open -b com.mitchellh.ghostty"; } ];
              }
            ];
          }
          {
            description = "Tap Caps Lock for Escape; hold it for Hyper (Control+Option+Command+Shift)";
            manipulators = [
              {
                type = "basic";
                from = {
                  key_code = "caps_lock";
                  modifiers.optional = [ "any" ];
                };
                to = [
                  {
                    key_code = "left_shift";
                    lazy = true;
                    modifiers = [
                      "left_command"
                      "left_control"
                      "left_option"
                    ];
                  }
                ];
                to_if_alone = [ { key_code = "escape"; } ];
                parameters."basic.to_if_alone_timeout_milliseconds" = 200;
              }
            ];
          }
          {
            description = "Tap Return for Return; hold it for Control";
            manipulators = [
              {
                type = "basic";
                from = {
                  key_code = "return_or_enter";
                  modifiers.optional = [ "any" ];
                };
                to = [
                  {
                    key_code = "right_control";
                    lazy = true;
                  }
                ];
                to_if_alone = [ { key_code = "return_or_enter"; } ];
                parameters."basic.to_if_alone_timeout_milliseconds" = 200;
              }
            ];
          }
          {
            description = "Press Left Shift and Right Shift together to toggle Caps Lock";
            manipulators = [
              {
                type = "basic";
                from = {
                  key_code = "right_shift";
                  modifiers = {
                    mandatory = [ "left_shift" ];
                    optional = [ "caps_lock" ];
                  };
                };
                to = [
                  {
                    key_code = "caps_lock";
                    hold_down_milliseconds = 200;
                  }
                  { key_code = "vk_none"; }
                ];
              }
              {
                type = "basic";
                from = {
                  key_code = "left_shift";
                  modifiers = {
                    mandatory = [ "right_shift" ];
                    optional = [ "caps_lock" ];
                  };
                };
                to = [
                  {
                    key_code = "caps_lock";
                    hold_down_milliseconds = 200;
                  }
                  { key_code = "vk_none"; }
                ];
              }
            ];
          }
        ];
      }
    ];
  };

  # Karabiner watches the configuration's parent directory and explicitly
  # supports linking that complete directory, but not karabiner.json alone.
  karabinerDirectory = pkgs.runCommand "karabiner-configuration" { } ''
    mkdir -p "$out"
    printf '%s\n' ${pkgs.lib.escapeShellArg (builtins.toJSON karabinerConfiguration)} > "$out/karabiner.json"
  '';
in
{
  # Karabiner requires a writable, user-owned configuration directory. It
  # rewrites karabiner.json at runtime (selected profile and any GUI edit) and
  # runs a permission check on the directory before loading it. Pointing
  # ~/.config/karabiner at the read-only, root-owned Nix store makes that check
  # fail with `permissions failed: ~/.config/karabiner: Operation not
  # permitted`, and the configuration is silently never applied.
  #
  # So install a real file into a real directory and reassert the declared
  # content on every activation. Karabiner owns runtime drift between
  # activations; Nix owns the desired state. karabiner.json itself must not be a
  # symlink either, or Karabiner cannot detect configuration changes.
  # (https://karabiner-elements.pqrs.org/docs/manual/misc/configuration-file-path/)
  home.activation.installKarabinerConfiguration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    configDirectory="$HOME/.config/karabiner"

    # Older generations symlinked the whole directory into the store. Replace
    # that link, but never touch an unmanaged real directory's other contents.
    if [[ -L "$configDirectory" ]]; then
      run rm -f "$configDirectory"
    fi

    run mkdir -p "$configDirectory"

    # Rewrite and restart ONLY when the declared content actually differs.
    #
    # Both halves of this matter. `install` copies unconditionally, so it bumps
    # karabiner.json's mtime on every activation even when the bytes are
    # identical — enough on its own to make a watcher think something changed.
    # And `kickstart -k` means kill-and-restart, so leaving it ungated took the
    # keyboard remapper down during every activation in the repository,
    # including ones that touch nothing but, say, the mouse. Keyboard input
    # briefly stops being remapped, which is a real cost for no benefit.
    #
    # Karabiner still owns runtime drift between activations; Nix reasserts the
    # desired content only when that desired content has changed. `cmp` also
    # fails when the destination is missing, which correctly installs it.
    if /usr/bin/cmp -s ${karabinerDirectory}/karabiner.json "$configDirectory/karabiner.json"; then
      verboseEcho "Karabiner configuration is already current; not restarting it"
    else
      run /usr/bin/install -m 0644 ${karabinerDirectory}/karabiner.json \
        "$configDirectory/karabiner.json"

      userId=$(/usr/bin/id -u)
      service="gui/$userId/org.pqrs.service.agent.karabiner_console_user_server"
      if /bin/launchctl print "$service" >/dev/null 2>&1; then
        run /bin/launchctl kickstart -k "$service"
      fi
    fi
  '';
}

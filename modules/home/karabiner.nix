{ pkgs, ... }:
let
  karabinerConfiguration = {
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
  home.file.".config/karabiner" = {
    source = karabinerDirectory;
    recursive = false;
    onChange = ''
      userId=$(/usr/bin/id -u)
      service="gui/$userId/org.pqrs.service.agent.karabiner_console_user_server"
      if /bin/launchctl print "$service" >/dev/null 2>&1; then
        run /bin/launchctl kickstart -k "$service"
      fi
    '';
  };
}

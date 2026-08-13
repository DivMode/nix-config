{ pkgs, ... }:
let
  disableExternalSpotlight = pkgs.writeShellScript "disable-external-spotlight" ''
    shopt -s nullglob
    failures=0

    for volume in /Volumes/*; do
      if ! internal=$(
        /usr/sbin/diskutil info -plist "$volume" \
          | /usr/bin/plutil -extract Internal raw -
      ); then
        /usr/bin/logger -t disable-external-spotlight \
          "Could not classify mounted volume: $volume"
        failures=1
        continue
      fi

      if [[ "$internal" == "false" ]]; then
        reconciled=0

        for attempt in 1 2 3; do
          if output=$(
            /usr/bin/mdutil -i off "$volume" 2>&1 \
              && /usr/bin/mdutil -d "$volume" 2>&1
          ); then
            reconciled=1
            /usr/bin/logger -t disable-external-spotlight \
              "Spotlight indexing and search disabled: $volume"
            break
          fi

          /usr/bin/logger -t disable-external-spotlight \
            "Attempt $attempt failed for $volume: $output"
          /bin/sleep 2
        done

        if [[ "$reconciled" -ne 1 ]]; then
          failures=1
        fi
      fi
    done

    exit "$failures"
  '';
in
{
  launchd.daemons.disable-external-spotlight = {
    command = "${disableExternalSpotlight}";
    serviceConfig = {
      RunAtLoad = true;
      StartOnMount = true;
      ProcessType = "Background";
    };
  };
}

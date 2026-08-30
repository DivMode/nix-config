# The cross-links that hold the orchestration documentation together, checked.
#
# WHY THIS EXISTS. The design record in ./orchestration-architecture.md is
# reachable only through links from five other files, and it links back out to
# three. None of that is exercised by anything: a rename, a move, or a tidied
# heading breaks a link in a PUBLIC repository and nothing says so until a
# reader hits a 404. Prose drifts silently; that is the whole reason the
# instruction document next door is checked rather than trusted.
#
# It is deliberately narrow. It does not lint every Markdown file in the tree,
# because a general link checker is a different tool with a different failure
# budget. It checks exactly the links whose breakage would strand the document
# the rest of this system's reasoning lives in.
#
# The set of OUTBOUND links is closed on purpose: adding a new relative link to
# the design record fails this check until the target is declared here. That is
# the point — an unchecked link is how the next dead one gets in.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  document = ./orchestration-architecture.md;

  # Files that must link TO the design record, and the exact relative path each
  # one has to use from where it sits. Written out rather than derived, so a
  # file moved to a different depth fails here instead of silently keeping a
  # link that no longer resolves.
  inbound = {
    "README.md" = {
      source = ../README.md;
      link = "docs/orchestration-architecture.md";
    };
    "ai/README.md" = {
      source = ../ai/README.md;
      link = "../docs/orchestration-architecture.md";
    };
    "ai/tandem/README.md" = {
      source = ../ai/tandem/README.md;
      link = "../../docs/orchestration-architecture.md";
    };
    "docs/architecture.md" = {
      source = ./architecture.md;
      link = "orchestration-architecture.md";
    };
    "docs/state-boundary.md" = {
      source = ./state-boundary.md;
      link = "orchestration-architecture.md";
    };
  };

  # Every relative link the design record is allowed to contain, and the file
  # each one must resolve to. `http` links are not checked: this repository
  # cannot assert anything about a remote host, and a check that needs the
  # network is a check that fails for the wrong reason.
  outbound = {
    "../ai/tandem/README.md" = ../ai/tandem/README.md;
    "../ai/instructions/orchestration.md" = ../ai/instructions/orchestration.md;
    "state-boundary.md" = ./state-boundary.md;
  };

  # `<relative link>\t<store path of the file it must resolve to>`.
  outboundFile = pkgs.writeText "orchestration-doc-outbound" (
    lib.concatStrings (lib.mapAttrsToList (link: target: "${link}\t${target}\n") outbound)
  );

  # `<repository path>\t<store path>\t<required link>`.
  inboundFile = pkgs.writeText "orchestration-doc-inbound" (
    lib.concatStrings (
      lib.mapAttrsToList (name: entry: "${name}\t${entry.source}\t${entry.link}\n") inbound
    )
  );
in
{
  tests =
    pkgs.runCommand "orchestration-docs-tests"
      {
        inherit document;
      }
      ''
        fail() { echo "orchestration-docs: $*" >&2; exit 1; }
        tab="$(printf '\t')"

        # 1. Everything that is supposed to point at the design record still
        #    does, using the relative path that actually resolves from where it
        #    lives.
        while IFS="$tab" read -r name source link; do
          [ -n "$name" ] || continue
          grep -qF -- "]($link)" "$source" \
            || fail "$name no longer links to the design record as ($link)"
        done < ${inboundFile}

        # 2. Every relative link the design record makes resolves to a real
        #    file. The store path is the file's current content, so a deleted
        #    or renamed target fails at evaluation before this even runs.
        while IFS="$tab" read -r link target; do
          [ -n "$link" ] || continue
          [ -f "$target" ] \
            || fail "the design record links to $link, which is not a file"
          grep -qF -- "]($link)" "$document" \
            || fail "the design record no longer links to $link; drop it from docs/links.nix"
        done < ${outboundFile}

        # 3. The outbound set is CLOSED. A new relative link must be declared
        #    above, or it is a link nothing checks — which is exactly how the
        #    next dead one gets in.
        #    `grep -o` rather than a line-oriented sed capture: two links on one
        #    line would hide one of them from a greedy match, and hiding the
        #    unchecked one is the exact failure this guards against.
        #
        #    `http` links are separated out and NOT checked. This document
        #    cites external specifications and vendor documentation on purpose,
        #    and a check that reaches the network fails when a site is slow, a
        #    proxy blocks it, or the build has no network at all — none of which
        #    is a defect in this repository. External URLs are references; local
        #    link integrity is what this asserts.
        grep -o ']([^)]*)' "$document" \
          | sed 's/^](//; s/)$//' \
          | sort -u > all-links

        grep -v '^http' all-links | grep -v '^#' | sort -u > used
        grep '^#' all-links | sed 's/^#//' | sort -u > anchors-used

        cut -f1 ${outboundFile} | sort -u > declared

        undeclared=$(comm -23 used declared)
        [ -z "$undeclared" ] \
          || fail "the design record has relative links that docs/links.nix does not check: $undeclared"

        # 4. In-page anchors resolve to a heading that still exists. A renamed
        #    or renumbered section silently strands every cross-reference to it,
        #    and this document cross-references its own sections by number.
        #    Slugged the way a Markdown renderer does: lowercase, punctuation
        #    dropped, spaces to hyphens.
        grep '^##* ' "$document" \
          | sed 's/^#* //' \
          | tr '[:upper:]' '[:lower:]' \
          | sed 's/[^a-z0-9 -]//g; s/  *$//; s/ /-/g' \
          | sort -u > anchors-present

        missing=$(comm -23 anchors-used anchors-present)
        [ -z "$missing" ] \
          || fail "the design record links to headings that do not exist: $missing"

        touch "$out"
      '';
}

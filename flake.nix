{
  description = "Scripts to help with maintenance of meta.mainProgram in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (builtins) attrValues;
      inherit (pkgs) writeShellApplication;

      get-bins-in-store-path = writeShellApplication {
        name = "get-bins-in-store-path";
        runtimeInputs = attrValues { inherit (pkgs) gnused nix ripgrep; };
        text = ''
          store_path="$1"
          bins=$(nix store ls --store https://cache.nixos.org  "$store_path"/bin/ 2> /dev/null  \
            | sed -E 's/\.\/(.*)/\1/')
          # Workaround for https://github.com/NixOS/nix/issues/6498
          if [ "$bins" = "bin" ]; then
            nix build --no-link "$store_path" 2> /dev/null
            bins=$(nix store ls "$store_path"/bin/ 2> /dev/null | sed -E 's/\.\/(.*)/\1/')
          fi
          echo -n "$bins" | rg --invert-match '.*-wrapped'
        '';
      };

      write-main-program-line = writeShellApplication {
        name = "write-main-program-line";
        runtimeInputs = attrValues { inherit (pkgs) gnugrep gnused; };
        text = ''
          bin="$1"
          file="$2"
          meta_attr=maintainers
          line="$(grep $meta_attr' =' "$file" || echo "")"
          if [ -z "$line" ]; then
            meta_attr=license
            line="$(grep $meta_attr' =' "$file" || echo "")"
          fi
          if [ "$line" != "" ] && ! grep 'mainProgram = ' "$file" > /dev/null; then
            indent=$(echo "$line" | sed -E 's/^( +)'$meta_attr' =.*/\1/g')
            sed -E -i "/''${meta_attr} = .*/a \\
        ''${indent}mainProgram = \"$bin\";" "$file" 2> /dev/null
          else
            exit 1
          fi
        '';
      };

      get-single-bin-for-package = writeShellApplication {
        name = "get-single-bin-for-package";
        runtimeInputs = attrValues {
          inherit (pkgs) coreutils jq ripgrep;
          inherit get-bins-in-store-path write-main-program-line;
        };
        text = ''
          name=$(echo "$1" | jq -r '.name')
          pname=$(echo "$1" | jq -r '.pname')
          store_path=$(echo "$1" | jq -r '.storePath')

          bins=$(get-bins-in-store-path "$store_path")

          # If package doesn't have a single bin, or the single bin matches `name` or `pname`, skip
          if [ "$(echo "$bins" | wc -l)" != "1" ] \
            || echo "$bins" | rg '^('"$name"'|'"$pname"')$' > /dev/null; then
            exit 1
          fi
          echo "$bins"
        '';
      };

      add-main-program-for-package = writeShellApplication {
        name = "add-main-program-for-package";
        runtimeInputs = attrValues {
          inherit (pkgs) gnused jq;
          inherit get-single-bin-for-package write-main-program-line;
        };
        text = ''
          name=$(echo "$1" | jq -r '.name')
          file=$(echo "$1" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          bin=$(get-single-bin-for-package "$1")

          # If package is auto-generated, skip
          if echo "$file" | rg '(haskell-modules|node-packages)' > /dev/null; then exit; fi

          if ! write-main-program-line "$bin" "$file"; then
            echo ""
            echo Failed to add "$bin" as meta.mainProgram for "$name" in:
            echo "$file"
            echo ""
          fi
        '';
      };

      print-main-program-for-node-package = writeShellApplication {
        name = "print-main-program-for-node-package";
        runtimeInputs = attrValues {
          inherit (pkgs) gnused jq;
          inherit get-single-bin-for-package;
        };
        text = ''
          name=$(echo "$1" | jq -r '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
          bin=$(get-single-bin-for-package "$1")
          echo "$name" = \""$bin"\"
        '';
      };
    in
    {
      packages.add-main-programs = writeShellApplication {
        name = "add-main-programs";
        runtimeInputs = attrValues {
          inherit (pkgs) jq nix parallel;
          inherit add-main-program-for-package;
        };
        text = ''
          nix eval --json \
            --argstr nixpkgs "$1" \
            --argstr system ${system} \
            -f ${./packages-info.nix} topLevelPkgs.woMainProgram \
              | jq -c .[] \
              | parallel --eta --no-notice "add-main-program-for-package {}";
        '';
      };

      packages.get-node-main-programs = writeShellApplication {
        name = "get-node-main-programs";
        runtimeInputs = attrValues {
          inherit (pkgs) jq nix parallel;
          inherit print-main-program-for-node-package;
        };
        text = ''
          nix eval --json \
            --argstr nixpkgs "$1" \
            --argstr system ${system} \
            -f ${./packages-info.nix} nodePackages.woMainProgram \
              | jq -c .[] \
              | parallel --no-notice "print-main-program-for-node-package {}";
        '';
      };
    }
  );
}

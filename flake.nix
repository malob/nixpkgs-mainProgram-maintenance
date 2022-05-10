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

      write-mainprog-line = writeShellApplication {
        name = "write-mainprog-line";
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

      get-bin-for-pkgs = writeShellApplication {
        name = "get-bin-for-pkgs";
        runtimeInputs = attrValues {
          inherit (pkgs) coreutils jq ripgrep;
          inherit get-bins-in-store-path write-mainprog-line;
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

      add-mainprog = writeShellApplication {
        name = "add-mainprog";
        runtimeInputs = attrValues {
          inherit (pkgs) gnused jq;
          inherit get-bin-for-pkgs write-mainprog-line;
        };
        text = ''
          name=$(echo "$1" | jq -r '.name')
          file=$(echo "$1" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          bin=$(get-bin-for-pkgs "$1")

          # If package is auto-generated, skip
          if echo "$file" | rg '(haskell-modules|node-packages)' > /dev/null; then exit; fi

          if ! write-mainprog-line "$bin" "$file"; then
            echo ""
            echo Failed to add "$bin" as meta.mainProgram for "$name" in:
            echo "$file"
            echo ""
          fi
        '';
      };

      mainprog-info-node = writeShellApplication {
        name = "mainprog-info-node";
        runtimeInputs = attrValues {
          inherit (pkgs) gnused jq;
          inherit get-bin-for-pkgs;
        };
        text = ''
          name=$(echo "$1" | jq -r '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
          bin=$(get-bin-for-pkgs "$1")
          echo "$name" = \""$bin"\"
        '';
      };

      mainprog-info-perl = writeShellApplication {
        name = "mainprog-info-perl";
        runtimeInputs = attrValues {
          inherit (pkgs) gnused jq;
          inherit get-bin-for-pkgs;
        };
        text = ''
          pname=$(echo "$1" | jq -r '.pname' | sed -E 's/perl[0-9]+.[0-9]+.[0-9]+-//')
          bin=$(get-bin-for-pkgs "$1")
          echo For "$pname" add:
          echo "      mainProgram = \"$bin\";"
        '';
      };

      run-script = writeShellApplication {
        name = "run-script";
        runtimeInputs = attrValues { inherit (pkgs) jq nix parallel; };
        text = ''
          script="$1"
          pkgs_info="$2"
          nixpkgs="$3"
          nix eval --json \
            --argstr nixpkgs "$nixpkgs" \
            --argstr system ${system} \
            -f ${./packages-info.nix} "$pkgs_info" \
              | jq -c .[] \
              | parallel --no-notice "$script {}";
        '';
      };
    in
    {
      packages.add-missing-mainprogs = writeShellApplication {
        name = "add-missing-mainprogs";
        runtimeInputs = attrValues {
          inherit (pkgs) which;
          inherit add-mainprog run-script;
        };
        text = ''run-script "$(which add-mainprog)" top-level.wo-mainprog "$1"'';
      };

      packages.print-missing-mainprogs-node = writeShellApplication {
        name = "print-missing-mainprogs-node";
        runtimeInputs = attrValues {
          inherit (pkgs) which;
          inherit mainprog-info-node run-script;
        };
        text = ''
          echo "Add the following in:"
          echo "$1"/pkgs/development/node-packages/default.nix
          echo ""
          run-script "$(which mainprog-info-node)" node.wo-mainprog "$1"
        '';
      };

      packages.print-missing-mainprogs-perl = writeShellApplication {
        name = "print-missing-mainprogs-perl";
        runtimeInputs = attrValues {
          inherit (pkgs) which;
          inherit mainprog-info-perl run-script;
        };
        text = ''
          echo "Add the following in:"
          echo "$1"/pkgs/top-level/perl-packages.nix
          echo ""
          run-script "$(which mainprog-info-perl)" perl.wo-mainprog "$1"
        '';
      };
    }
  );
}

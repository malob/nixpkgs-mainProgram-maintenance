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


      # Helper scripts -----------------------------------------------------------------------------

      get-bins-in-local-store = writeShellApplication {
        name = "get-bins-in-local-store";
        runtimeInputs = [ pkgs.nix ];
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"
          nix build -f "$nixpkgs" --argstr system ${system} --no-link "$attr_name" 2> /dev/null
          nix store ls "$store_path"/bin/ 2> /dev/null || echo -n ""
        '';
      };

      get-bins-in-store = writeShellApplication {
        name = "get-bins-in-store";
        runtimeInputs = [ get-bins-in-local-store ] ++ attrValues {
          inherit (pkgs) gnused nix ripgrep;
        };
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"

          if nix store ls --store https://cache.nixos.org "$store_path" > /dev/null 2>&1; then
            bins=$(nix store ls --store https://cache.nixos.org "$store_path"/bin/ 2> /dev/null \
              || echo -n "")
            # Workaround for https://github.com/NixOS/nix/issues/6498
            if [ "$bins" = "bin" ]; then
              bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
            fi
          else
            bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
          fi
          echo -n "$bins" | sed -E 's#\./##' | rg --invert-match '.*-wrapped'
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

      get-bin-for-pkg = writeShellApplication {
        name = "get-bin-for-pkg";
        runtimeInputs = [
          get-bins-in-store
          write-mainprog-line
        ] ++ attrValues { inherit (pkgs) coreutils jq ripgrep; };
        text = ''
          attr_name=$(echo "$1" | jq -r '.attrName')
          name=$(echo "$1" | jq -r '.name')
          pname=$(echo "$1" | jq -r '.pname')
          store_path=$(echo "$1" | jq -r '.storePath')
          nixpkgs="$2"

          bins=$(get-bins-in-store "$store_path" "$attr_name" "$nixpkgs")

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
        runtimeInputs = [
          get-bin-for-pkg
          write-mainprog-line
        ] ++ attrValues { inherit (pkgs) gnused jq; };
        text = ''
          name=$(echo "$1" | jq -r '.name')
          file=$(echo "$1" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          nixpkgs="$2"

          # If package is auto-generated, skip
          if echo "$file" | rg '(haskell-modules|node-packages|perl-packages)' > /dev/null; then
            exit 0
          fi

          bin=$(get-bin-for-pkg "$1" "$nixpkgs")

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
        runtimeInputs = [ get-bin-for-pkg pkgs.jq ];
        text = ''
          name=$(echo "$1" | jq -r '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
          nixpkgs="$2"
          bin=$(get-bin-for-pkg "$1" "$nixpkgs")
          echo "  $name = \"$bin\";"
        '';
      };

      mainprog-info-perl = writeShellApplication {
        name = "mainprog-info-perl";
        runtimeInputs = [ get-bin-for-pkg ] ++ attrValues { inherit (pkgs) gnused jq; };
        text = ''
          pname=$(echo "$1" | jq -r '.pname' | sed -E 's/perl[0-9]+.[0-9]+.[0-9]+-//')
          nixpkgs="$2"
          bin=$(get-bin-for-pkg "$1" "$nixpkgs")
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
            --show-trace \
            -f ${./packages-info.nix} "$pkgs_info" \
              | jq -c .[] \
              | parallel --no-notice "$script {} $nixpkgs";
        '';
      };


      # Main scripts -------------------------------------------------------------------------------

      add-missing-mainprogs-ocaml = writeShellApplication {
        name = "add-missing-mainprogs-ocaml";
        runtimeInputs = [ add-mainprog run-script pkgs.which ];
        text = ''run-script "$(which add-mainprog)" ocamlPackages.wo-mainprog "$1"'';
      };

      add-missing-mainprogs-python = writeShellApplication {
        name = "add-missing-mainprogs-python";
        runtimeInputs = [ add-mainprog run-script pkgs.which ];
        text = ''
          run-script "$(which add-mainprog)" python2Packages.wo-mainprog "$1" || :
          run-script "$(which add-mainprog)" python3Packages.wo-mainprog "$1" || :
        '';
      };

      add-missing-mainprogs-top-level = writeShellApplication {
        name = "add-missing-mainprogs-top-level";
        runtimeInputs = [ add-mainprog run-script pkgs.which ];
        text = ''run-script "$(which add-mainprog)" pkgs.wo-mainprog "$1"'';
      };

      add-missing-mainprogs = writeShellApplication {
        name = "add-missing-mainprogs";
        runtimeInputs = [
          add-missing-mainprogs-ocaml
          add-missing-mainprogs-python
          add-missing-mainprogs-top-level
        ];
        text = ''
          echo ""
          echo "--- Adding meta.mainProgram for ocamlPackages ---"
          add-missing-mainprogs-ocaml "$1" || :

          echo ""
          echo "--- Adding meta.mainProgram for python{2,3}Packages ---"
          add-missing-mainprogs-python "$1" || :

          echo ""
          echo "--- Adding meta.mainProgram for top-level packages ---"
          add-missing-mainprogs-top-level "$1" || :
        '';
      };

      print-missing-mainprogs-node = writeShellApplication {
        name = "print-missing-mainprogs-node";
        runtimeInputs = [ mainprog-info-node run-script pkgs.which ];
        text = ''
          echo "Add the following in:"
          echo "$1"/pkgs/development/node-packages/main-programs.nix
          echo ""
          run-script "$(which mainprog-info-node)" nodePackages.wo-mainprog "$1"
        '';
      };

      print-missing-mainprogs-perl = writeShellApplication {
        name = "print-missing-mainprogs-perl";
        runtimeInputs = [ mainprog-info-perl run-script pkgs.which ];
        text = ''
          echo "Add the following in:"
          echo "$1"/pkgs/top-level/perl-packages.nix
          echo ""
          run-script "$(which mainprog-info-perl)" perlPackages.wo-mainprog "$1"
        '';
      };
    in
    {
      packages = {
        inherit
          add-missing-mainprogs
          add-missing-mainprogs-ocaml
          add-missing-mainprogs-python
          add-missing-mainprogs-top-level
          print-missing-mainprogs-node
          print-missing-mainprogs-perl;
      };
    }
  );
}

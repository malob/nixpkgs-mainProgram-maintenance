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


      # Helper scripts to find bins for a package --------------------------------------------------

      # Output contents of /bin in a given store path by first building the package and then
      # querying the local store.
      get-bins-in-local-store = writeShellApplication {
        name = "get-bins-in-local-store";
        runtimeInputs = [ pkgs.coreutils pkgs.nix ];
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"

          # If package previously failed to build, skip
          touch failed-builds.txt
          grep "$store_path" failed-builds.txt > /dev/null && exit 1

          # If the package hasn't been build, build it first
          if ! nix store ls "$store_path" > /dev/null 2>&1; then
            # >&2 echo "Building $attr_name"
            NIXPKGS_ALLOW_UNFREE=1 timeout 5m \
              nix build -f "$nixpkgs" --argstr system ${system} --no-link "$attr_name" 2> /dev/null \
                || echo "$store_path" >> failed-builds.txt
          fi
          nix store ls "$store_path"/bin/ 2> /dev/null
        '';
      };

      # Output contents of /bin in a given store path by first attempting the query the contents of
      # the store path in https://cache.nixos.org, and falling back to using
      # `get-bins-in-local-store` if the store path isn't available in the binary cache.
      get-bins-in-store = writeShellApplication {
        name = "get-bins-in-store";
        runtimeInputs = [
          get-bins-in-local-store
        ] ++ attrValues { inherit (pkgs) gnused hydra-check nix ripgrep; };
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"

          # If package previously failed to build, skip
          touch failed-builds.txt
          grep "$store_path" failed-builds.txt > /dev/null && exit 1

          # Check if store path is present in the binary cache, if it is, get contents of /bin.
          if nix store ls --store https://cache.nixos.org "$store_path" > /dev/null 2>&1; then
            bins=$(nix store ls --store https://cache.nixos.org "$store_path"/bin/ 2> /dev/null)
            # Workaround for https://github.com/NixOS/nix/issues/6498
            if [ "$bins" = "bin" ]; then
              bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
            fi
          # Otherwise, build package locally, if it didn't fail on Hydra and get contents of /bin
          # from local store.
          else
            hydra-check --channel master --arch ${system} "$attr_name" \
              | rg '(F|f)ailed' > /dev/null && exit 1
            bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
          fi
          if [ -z "$bins" ]; then exit 1; fi
          echo "$bins" | sed -E 's#\./##'
        '';
      };

      # Output a single bin name, if package only containts one bin, and that the name of that bin
      # differs from the package's `name` or `pname`, which would cause `nix run` to fail.
      get-bin-for-pkg = writeShellApplication {
        name = "get-bin-for-pkg";
        runtimeInputs = [
          get-bins-in-store
        ] ++ attrValues { inherit (pkgs) coreutils jq ripgrep; };
        text = ''
          attr_name=$(echo "$1" | jq -r '.attrName')
          name=$(echo "$1" | jq -r '.name')
          pname=$(echo "$1" | jq -r '.pname')
          store_path=$(echo "$1" | jq -r '.storePath')
          nixpkgs="$2"

          # Get bins for the package.
          bins=$(get-bins-in-store "$store_path" "$attr_name" "$nixpkgs")
          # Filter out wrapped bins since we don't care about them.
          bins=$(echo "$bins" | rg --invert-match '.*-wrapped')

          # If package doesn't have a single bin, or the single bin matches `name` or `pname`, skip
          if [ "$(echo "$bins" | wc -l)" != "1" ] \
            || echo "$bins" | rg '^('"$name"'|'"$pname"')$' > /dev/null; then
            exit 1
          fi
          echo "$bins"
        '';
      };


      # Helper scripts to insert mainProgram into files --------------------------------------------

      # Insert a `mainProgram` line into a file containing a package definition.
      write-mainprog-line = writeShellApplication {
        name = "write-mainprog-line";
        runtimeInputs = attrValues { inherit (pkgs) gnugrep gnused; };
        text = ''
          bin="$1"
          file="$2"

          # Find line in file under which the `mainProgram` line should be inserted.
          meta_attr=maintainers
          line="$(grep $meta_attr' =' "$file" || echo "")"
          if [ -z "$line" ]; then
            meta_attr=license
            line="$(grep $meta_attr' =' "$file" || echo "")"
          fi

          # If a suitable line is found, insert `mainProgram` line below it.
          if [ -n "$line" ] && ! grep 'mainProgram = ' "$file" > /dev/null; then
            indent=$(echo "$line" | sed -E 's/^( +)'$meta_attr' =.*/\1/g')
            sed -E -i "/''${meta_attr} = .*/a \\
        ''${indent}mainProgram = \"$bin\";" "$file" 2> /dev/null
          else
            exit 1
          fi
        '';
      };

      # Check whether package is a candidate for adding `meta.mainProgram` and if it is, attempt to
      # insert it into the file where the package is defined.
      add-mainprog = writeShellApplication {
        name = "add-mainprog";
        runtimeInputs = [
          get-bin-for-pkg
          write-mainprog-line
        ] ++ attrValues { inherit (pkgs) gnused jq; };
        text = ''
          attr_name=$(echo "$1" | jq -r '.attrName')
          file=$(echo "$1" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          nixpkgs="$2"

          # Skip if package is defined in a file where auto-insertion doesn't make sense, or isn't
          # supported by the `write-mainprog-line` script.
          if echo "$file" | rg '(haskell-modules|node-packages|perl-packages)' > /dev/null; then
            exit 0
          fi

          # Attempt to get `mainProgram` candiate
          bin=$(get-bin-for-pkg "$1" "$nixpkgs") || exit 0

          # Attempt to insert `mainProgram` line into the file where package is defined, and if
          # insertion fails, print a message info required to try and add it manually.
          if write-mainprog-line "$bin" "$file"; then
            echo "Added '$bin' as meta.mainProgram for package '$attr_name'"
          else
            echo ""
            echo "Failed to add '$bin' as meta.mainProgram for '$attr_name' in:"
            echo "$file"
            echo ""
          fi
        '';
      };


      # Helper scripts for printing mainProgam info ------------------------------------------------

      # Output `mainProgram` info in a form suitable for insertion into:
      # pkgs/development/node-packages/main-programs.nix
      mainprog-info-node = writeShellApplication {
        name = "mainprog-info-node";
        runtimeInputs = [ get-bin-for-pkg pkgs.jq ];
        text = ''
          name=$(echo "$1" | jq -r '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
          nixpkgs="$2"
          bin=$(get-bin-for-pkg "$1" "$nixpkgs") || exit 0
          echo "  $name = \"$bin\";"
        '';
      };

      # Output `mainProgram` info in a form suitable for insertion into:
      # pkgs/top-level/perl-packages.nix
      mainprog-info-perl = writeShellApplication {
        name = "mainprog-info-perl";
        runtimeInputs = [ get-bin-for-pkg pkgs.jq ];
        text = ''
          attr_name=$(echo "$1" | jq -r '.attrName')
          nixpkgs="$2"
          bin=$(get-bin-for-pkg "$1" "$nixpkgs") || exit 0
          echo For "$attr_name" add:
          echo "      mainProgram = \"$bin\";"
        '';
      };


      # Other helper scripts -----------------------------------------------------------------------

      remove-invalid-mainprog = writeShellApplication {
        name = "remove-invalid-mainprog";
        runtimeInputs = [
          get-bins-in-store
        ] ++ attrValues { inherit (pkgs) gnugrep gnused jq nix; };
        text = ''
          attr_name=$(echo "$1" | jq -r '.attrName')
          store_path=$(echo "$1" | jq -r '.storePath')
          mainprog=$(echo "$1" | jq -r '.mainProgram')
          file=$(echo "$1" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          nixpkgs="$2"

          bins=$(get-bins-in-store "$store_path" "$attr_name" "$nixpkgs" || echo "")

          if echo "$bins" | grep "$mainprog" > /dev/null; then exit 0; fi

          if [ -n "$bins" ]; then
            echo "Removing meta.mainProgram for '$attr_name': no bins matched '$mainprog'"
          elif nix store ls --store https://cache.nixos.org "$store_path" > /dev/null 2>&1 \
            || nix store ls "$store_path" > /dev/null 2>&1
          then
            echo "Removing meta.mainProgram for '$attr_name': package has no executables"
          else
            echo "Failed to query store path for '$attr_name': package probably failed to build"
            exit 0
          fi
          if ! grep "mainProgram = \"$mainprog\"" "$file" > /dev/null; then
            echo ""
            echo "Failed to remove meta.mainProgram for '$attr_name' in:"
            echo "$file"
            echo ""
          else
             sed -i "/mainProgram = \"$mainprog\";/d" "$file"
          fi
        '';
      };

      run-script = writeShellApplication {
        name = "run-script";
        runtimeInputs = attrValues { inherit (pkgs) jq nix parallel; };
        text = ''
          script="$1"  # on of the main scripts from this project
          pkg_set="$2" # e.g., pkgs, or nodePackages etc.
          filter="$3"  # one of all, w-mainprog, or wo-mainprog
          nixpkgs="$4" # path to local nixpkgs
          nix eval --json \
            --argstr nixpkgs "$nixpkgs" \
            --argstr system ${system} \
            --argstr pkgSetName "$pkg_set" \
            -f ${./packages-info.nix} "$filter" \
              | jq -c .[] \
              | parallel --no-notice "$script {} $nixpkgs";
        '';
      };


      # Main scripts -------------------------------------------------------------------------------

      add-missing-mainprogs = writeShellApplication {
        name = "add-missing-mainprogs";
        runtimeInputs = [ run-script ];
        text = ''
          nixpkgs="$1" # path to local nixpkgs
          pkg_set="$2" # e.g., pkgs, or nodePackages etc.
          script="${add-mainprog}/bin/add-mainprog"
          if [ "$pkg_set" != "all" ]; then
            run-script "$script" "$pkg_set" wo-mainprog "$nixpkgs"
          else
            # echo ""
            # echo "--- Adding meta.mainProgram for ocamlPackages ---"
            # run-script "$script" ocamlPackages wo-mainprog "$nixpkgs"

            echo ""
            echo "--- Adding meta.mainProgram for python39Packages ---"
            run-script "$script" python39Packages wo-mainprog "$nixpkgs"

            echo ""
            echo "--- Adding meta.mainProgram for top-level packages ---"
            run-script "$script" pkgs wo-mainprog "$nixpkgs"
          fi
        '';
      };

      print-missing-mainprogs-node = writeShellApplication {
        name = "print-missing-mainprogs-node";
        runtimeInputs = [ run-script ];
        text = ''
          nixpkgs="$1" # path to local nixpkgs
          echo "Add the following in:"
          echo "$nixpkgs/pkgs/development/node-packages/main-programs.nix"
          echo ""
          run-script ${mainprog-info-node}/bin/mainprog-info-node nodePackages wo-mainprog "$nixpkgs"
        '';
      };

      print-missing-mainprogs-perl = writeShellApplication {
        name = "print-missing-mainprogs-perl";
        runtimeInputs = [ run-script ];
        text = ''
          nixpkgs="$1" # path to local nixpkgs
          echo "Add the following in:"
          echo "$nixpkgs/pkgs/top-level/perl-packages.nix"
          echo ""
          run-script ${mainprog-info-perl}/bin/mainprog-info-perl perlPackages wo-mainprog "$nixpkgs"
        '';
      };

      remove-invalid-mainprogs = writeShellApplication {
        name = "remove-invalid-mainprogs";
        runtimeInputs = [ run-script ];
        text = ''
          nixpkgs="$1" # path to local nixpkgs
          pkg_set="$2" # e.g., pkgs, or nodePackages etc.
          script="${remove-invalid-mainprog}/bin/remove-invalid-mainprog"
          if [ "$pkg_set" != "all" ]; then
            run-script "$script" "$pkg_set" w-mainprog "$nixpkgs"
          else
            echo ""
            echo "--- Removing invalid meta.mainProgram for ocamlPackages ---"
            run-script "$script" ocamlPackages w-mainprog "$nixpkgs"

            echo ""
            echo "--- Removing invalid meta.mainProgram for perlPackages ---"
            run-script "$script" perlPackages w-mainprog "$nixpkgs"

            echo ""
            echo "--- Removing invalid meta.mainProgram for python39Packages ---"
            run-script "$script" python39Packages w-mainprog "$nixpkgs"

            echo ""
            echo "--- Removing invalid meta.mainProgram for top-level packages ---"
            run-script "$script" pkgs w-mainprog "$nixpkgs"
          fi
        '';
      };
    in
    {
      packages = {
        inherit
          add-missing-mainprogs
          print-missing-mainprogs-node
          print-missing-mainprogs-perl
          remove-invalid-mainprogs;
      };
      packages.default = add-missing-mainprogs;
    }
  );
}

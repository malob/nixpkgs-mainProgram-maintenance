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

      jq-cmd = writeShellApplication {
        name = "jq-cmd";
        runtimeInputs = [ pkgs.jq ];
        text = ''echo "$1" | jq -e -r "$2";'';
      };

      nix-store-ls = writeShellApplication {
        name = "nix-store-ls";
        runtimeInputs = [ pkgs.nix ];
        text = ''nix store ls --store "$1" "$2" 2> /dev/null'';
      };

      # Helper scripts to find bins for a package --------------------------------------------------

      # Attempts to get contents of `bin/` in local store for a package, build if needed.
      get-bins-in-local-store = writeShellApplication {
        name = "get-bins-in-local-store";
        runtimeInputs = [ nix-store-ls jq-cmd ] ++ attrValues { inherit (pkgs) coreutils gnugrep nix; };
        text = ''
          info="$1" # output of `get-pkg-info`
          timeout="''${2:-5m}"

          store_path=$(jq-cmd "$info" '.store_path')

          # Fail if package previously failed to build.
          touch failed-builds.txt
          grep "$store_path" failed-builds.txt > /dev/null && exit 1

          # Check if the packages has already been build, and build it if it hasn't
          export NIXPKGS_ALLOW_UNFREE=1
          nix-store-ls daemon "$store_path" > /dev/null \
            || timeout "$timeout" nix build \
              --no-link \
              --argstr system ${system} \
              -f "$(jq-cmd "$info" '.nixpkgs')" \
              "$(jq-cmd "$info" '.attr_name')" 2> /dev/null \
            || echo "$store_path" >> failed-builds.txt

          nix-store-ls daemon "$store_path/bin/"
        '';
      };

      # Attempts to get contents of `bin/` for package first in local store, then remote store, then
      # local store again after attempting to build.
      get-bins-in-store = writeShellApplication {
        name = "get-bins-in-store";
        runtimeInputs = [
          get-bins-in-local-store
          jq-cmd
          nix-store-ls
        ] ++ attrValues { inherit (pkgs) gnugrep gnused hydra-check; };
        text = ''
          info="$1" # output of `get-pkg-info`
          store_path=$(jq-cmd "$info" '.store_path')

          # Check if store path is present in the local store, if it is, get contents of `bin/`.
          if nix-store-ls daemon "$store_path" > /dev/null; then

            bins=$(nix-store-ls daemon "$store_path/bin/")

          # Check if store path is present in the binary cache, if it is, get contents of `bin/`.
          elif nix-store-ls https://cache.nixos.org "$store_path" > /dev/null; then

            bins=$(nix-store-ls https://cache.nixos.org "$store_path/bin/")

            # Workaround for https://github.com/NixOS/nix/issues/6498
            [ "$bins" = "bin" ] && bins=$(get-bins-in-local-store "$info")

          # Check package failed on Hydra, if it didn't and get contents of `bin/` from local store.
          else
            hydra-check --channel master --arch ${system} "$(jq-cmd "$info" '.attr_name')" \
              | grep -E '(F|f)ailed' > /dev/null && exit 1
            bins=$(get-bins-in-local-store "$info")
          fi

          # Fail if `bin/` directory exists but is empty.
          [ -z "$bins" ] && exit 1

          echo "$bins" | sed -E 's#\./##'
        '';
      };

      # Get candidate `meta.mainProgram` bins for a package
      get-maingrog-candidates = writeShellApplication {
        name = "get-maingrog-candidates";
        runtimeInputs = [ get-bins-in-store jq-cmd pkgs.gnugrep ];
        text = ''
          info="$1" # output of `get-pkg-info`

          bins=$(get-bins-in-store "$info")

          name=$(jq-cmd "$info" '.name')
          pname=$(jq-cmd "$info" '.pname')

          # Fail if any executables match the packages `name` or `pname`.
          echo "$bins" | grep -E '^('"$name"'|'"$pname"')$' > /dev/null && exit 1

          # Filter out wrapped bins since we don't care about them.
          echo "$bins" | grep -E --invert-match '.*-wrapped'
        '';
      };


      # Helper scripts for adding/removing `meta.mainProgram` definitions --------------------------

      # Attempts to insert a `meta.mainProgram` definition for a package
      insert-mainprog-line = writeShellApplication {
        name = "insert-mainprog-line";
        runtimeInputs = [ jq-cmd ] ++ attrValues { inherit (pkgs) gnugrep gnused; };
        text = ''
          info="$1" # output of `get-pkg-info`
          bin="$2"

          # Fail if `meta.mainProgram` is already defined.
          jq-cmd "$info" '.main_program' > /dev/null && exit 1

          file=$(jq-cmd "$info" '.edit_info.file')
          line=$(jq-cmd "$info" '.edit_info.line')
          meta_attr=$(jq-cmd "$info" '.edit_info.meta_attr')

          # Fail if we know insertion point is isn't specific to the given package.
          echo "$file" | grep 'perl-modules/generic' > /dev/null && exit 1

          if echo "$file" | grep 'node-packages' > /dev/null; then
            name=$(jq-cmd "$info" '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
            sed -i "$line a\\
          $name = \"$bin\";" "$file"
          else
            indent=$(sed -n "$line p" "$file" | sed -E 's/^( +)'"$meta_attr"'.*/\1/')
            sed -i "$line a\\
        ''${indent}mainProgram = \"$bin\";" "$file"
          fi
        '';
      };

      # Figure out whether a package is a candidate for adding a `meta.mainProgram` definition, and
      # attempt to add it if it is.
      add-mainprog = writeShellApplication {
        name = "add-mainprog";
        runtimeInputs = [
          get-maingrog-candidates
          jq-cmd
          insert-mainprog-line
        ] ++ attrValues { inherit (pkgs) coreutils gnugrep gnused; };
        text = ''
          info="$1" # output of `get-pkg-info`

          attr_name=$(jq-cmd "$info" '.attr_name')

          # Skip if packages already has meta.mainProgram defined.
          jq-cmd "$info" '.main_program' > /dev/null \
            && echo "Package '$attr_name' already has meta.mainProgram defined" \
            && exit 0

          # Skip if package is defined in a file where auto-insertion doesn't make sense, e.g.,
          # cases where package derivation is auto-generated, and there isn't an established way to
          # define `meta.mainProgram` (like there is for `nodePackages`).
          file=$(jq-cmd "$info" '.position' | sed -E 's/(.+):[0-9]+/\1/')
          echo "$file" | grep 'haskell-modules' > /dev/null && exit 0

          # Get bins for package, and skip if we are unable to
          bins=$(get-maingrog-candidates "$info") || exit 0

          # Skip if there is more than one executable for package
          [ "$(echo "$bins" | wc -l)" = "1" ] || exit 0

          # Attempt to insert `mainProgram` line into the file where package is defined, and if
          # insertion fails, print a message with info to help guide the user to insert in manually.
          if insert-mainprog-line "$info" "$bins" ; then
            echo "Added '$bins' as meta.mainProgram for package '$attr_name'"
          else
            echo ""
            echo "Failed to add '$bins' as meta.mainProgram for '$attr_name' in:"
            echo "$file"
            echo ""
          fi
        '';
      };

      # Attempts to remove the `meta.mainProgram` definition for a package if the package's `name`
      # or `pname` match the `mainProgram`, or the package doesn't provide a bin that matches
      # `mainProgram'.
      remove-invalid-mainprog = writeShellApplication {
        name = "remove-invalid-mainprog";
        runtimeInputs = [
          get-bins-in-store
          jq-cmd
          nix-store-ls
        ] ++ attrValues { inherit (pkgs) gnugrep gnused; };
        text = ''
          info="$1" # output of `get-pkg-info`

          attr_name=$(jq-cmd "$info" '.attr_name')

          # Skip if package doesn't have a `meta.mainProgram` defined.
          main_program=$(jq-cmd "$info" '.main_program') \
            || { echo "Package '$attr_name' doesn't have meta.mainProgram defined" && exit 0; }

          bins=$(get-bins-in-store "$info" || echo "")

          name=$(jq-cmd "$info" '.name')
          pname=$(jq-cmd "$info" '.pname')
          store_path=$(jq-cmd "$info" '.store_path')

          if echo "$bins" | grep -E '^('"$name"'|'"$pname"')$' > /dev/null; then

            removal_reason="an executable matched name or pname"

          elif echo "$bins" | grep "$main_program" > /dev/null; then exit 0

          elif [ -n "$bins" ]; then

            removal_reason="no executables named '$main_program'"

          elif nix-store-ls daemon "$store_path" > /dev/null \
            || nix-store-ls https://cache.nixos.org "$store_path" > /dev/null; then

            removal_reason="package has no executables"

          else

            echo "Failed to query store path for '$attr_name': package probably failed to build"
            exit 0

          fi

          echo "Removing meta.mainProgram for '$attr_name': $removal_reason"
          sed -i "$(jq-cmd "$info" .edit_info.line) d" "$(jq-cmd "$info" .edit_info.file)"
        '';
      };


      # Main scripts -------------------------------------------------------------------------------

      get-pkg-names = writeShellApplication {
        name = "get-pkg-names";
        runtimeInputs = attrValues { inherit (pkgs)  nix jq; };
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]
          pkgs_w_mainprog="$3"   # whether to include packages with `meta.mainProgram` defined
          pkgs_wo_mainprog="$4"  # whether to include packages without `meta.mainProgram` defined

          nix eval --json \
            --argstr nixpkgs "$nixpkgs" \
            --argstr system ${system} \
            --arg pkgSetAttrPath "$pkg_set_attr_path" \
            --arg includePkgsWithMainProgram "$pkgs_w_mainprog" \
            --arg includePkgsWoMainProgram "$pkgs_wo_mainprog" \
            -f lib/package-names.nix output \
              | jq -r .[]
        '';
      };

      get-pkg-info = writeShellApplication {
        name = "get-pkg-info";
        runtimeInputs = attrValues { inherit (pkgs)  nix jq; };
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]
          pkg_name="$3"          # e.g., ack

          nix eval --json \
            --argstr nixpkgs "$nixpkgs" \
            --argstr system ${system} \
            --arg pkgSetAttrPath "$pkg_set_attr_path" \
            --argstr pkgName "$pkg_name" \
            -f lib/package-info.nix output \
              | jq -c
        '';
      };

      add-mps = writeShellApplication {
        name = "add-mps";
        runtimeInputs = [ add-mainprog get-pkg-info get-pkg-names ];
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]

          for pkg_name in $(get-pkg-names "$nixpkgs" "$pkg_set_attr_path" false true); do
            add-mainprog  "$(get-pkg-info "$nixpkgs" "$pkg_set_attr_path" "$pkg_name")"
          done
        '';
      };

      add-mps-interactive = writeShellApplication {
        name = "add-mps-interactive";
        runtimeInputs = [
          get-maingrog-candidates
          get-pkg-info
          get-pkg-names
          jq-cmd
          insert-mainprog-line
        ] ++ attrValues { inherit (pkgs) gnused nix; };
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]

          for pkg_name in $(get-pkg-names "$nixpkgs" "$pkg_set_attr_path" false true); do
            info=$(get-pkg-info "$nixpkgs" "$pkg_set_attr_path" "$pkg_name")
            attr_name=$(jq-cmd "$info" '.attr_name')

            # Skip if packages already has meta.mainProgram defined.
            jq-cmd "$info" '.main_program' > /dev/null \
              && echo "Package '$attr_name' already has meta.mainProgram defined" \
              && continue

            # shellcheck disable=SC2207
            bins=($(get-maingrog-candidates "$info")) || continue

            PS3="Select the executable to use as meta.mainProgram for '$attr_name':"
            select bin in "''${bins[@]}" "Skip" "Exclude" ; do
              if [ "$bin" = "Skip" ]; then
                echo "Skipped adding meta.mainProgram for '$attr_name'"
              elif [ "$bin" = "Exclude" ]; then
                pkg_attr_path=$(nix eval --expr "$pkg_set_attr_path ++ [ \"$pkg_name\" ]")
                sed -i "\$i\\
            $pkg_attr_path" lib/packages-to-skip.nix
                echo "Added '$pkg_attr_path' to lib/packages-to-skip.nix"
              elif insert-mainprog-line "$info" "$bin" ; then
                echo "Added '$bin' as meta.mainProgram for package '$attr_name'"
              else
                file=$(jq-cmd "$info" '.position' | sed -E 's/(.+):[0-9]+/\1/')
                echo ""
                echo "Failed to add '$bin' as meta.mainProgram for '$attr_name' in:"
                echo "$file"
                echo ""
              fi
              echo ""
              break
            done
          done
        '';
      };

      rm-mps = writeShellApplication {
        name = "rm-mps";
        runtimeInputs = [ get-pkg-info get-pkg-names remove-invalid-mainprog ];
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]

          for pkg_name in $(get-pkg-names "$nixpkgs" "$pkg_set_attr_path" true false); do
            remove-invalid-mainprog "$(get-pkg-info "$nixpkgs" "$pkg_set_attr_path" "$pkg_name")" "$nixpkgs"
          done
        '';
      };
    in
    {
      packages = {
        inherit
          get-pkg-names
          get-pkg-info
          add-mps
          add-mps-interactive
          rm-mps;

        default = add-mps;
      };
    }
  );
}

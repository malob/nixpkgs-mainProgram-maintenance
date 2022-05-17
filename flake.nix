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

      nix-store-ls = writeShellApplication {
        name = "nix-store-ls";
        runtimeInputs = [ pkgs.nix ];
        text = ''nix store ls --store "$1" "$2" 2> /dev/null'';
      };

      # Output contents of `bin/` in a given store path in the local store. If the store path
      # doesn't exist in the local store, try to build the package first.
      get-bins-in-local-store = writeShellApplication {
        name = "get-bins-in-local-store";
        runtimeInputs = [ nix-store-ls ] ++ attrValues { inherit (pkgs) coreutils gnugrep nix; };
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"
          timeout="''${4:-5m}"

          # Fail if package previously failed to build.
          touch failed-builds.txt
          grep "$store_path" failed-builds.txt > /dev/null && exit 1

          # If the package hasn't been build, build it first.
          if ! nix-store-ls daemon "$store_path" > /dev/null; then
            # >&2 echo "Building $attr_name"
            NIXPKGS_ALLOW_UNFREE=1 timeout "$timeout" \
              nix build -f "$nixpkgs" --argstr system ${system} --no-link "$attr_name" 2> /dev/null \
                || echo "$store_path" >> failed-builds.txt
          fi
          nix-store-ls daemon "$store_path/bin/"
        '';
      };

      # Output contents of /bin in a given store path by first attempting the query the contents of
      # the store path in https://cache.nixos.org, and falling back to using
      # `get-bins-in-local-store` if the store path isn't available in the binary cache.
      get-bins-in-store = writeShellApplication {
        name = "get-bins-in-store";
        runtimeInputs = [
          get-bins-in-local-store
          nix-store-ls
        ] ++ attrValues { inherit (pkgs) gnused hydra-check ripgrep; };
        text = ''
          store_path="$1"
          attr_name="$2"
          nixpkgs="$3"

          # Fail If package previously failed to build.
          touch failed-builds.txt
          grep "$store_path" failed-builds.txt > /dev/null && exit 1

          # Check if store path is present in the local store, if it is, get contents of `bin/`.
          if nix-store-ls daemon "$store_path" > /dev/null; then
            bins=$(nix-store-ls daemon "$store_path/bin/")
          # Check if store path is present in the binary cache, if it is, get contents of `bin/`.
          elif nix-store-ls https://cache.nixos.org "$store_path" > /dev/null; then
            bins=$(nix-store-ls https://cache.nixos.org "$store_path/bin/")
            # Workaround for https://github.com/NixOS/nix/issues/6498
            if [ "$bins" = "bin" ]; then
              bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
            fi
          # Build package locally, if it didn't fail on Hydra, and get contents of `bin/` from
          # local store.
          else
            hydra-check --channel master --arch ${system} "$attr_name" \
              | rg '(F|f)ailed' > /dev/null && exit 1
            bins=$(get-bins-in-local-store "$store_path" "$attr_name" "$nixpkgs")
          fi

          # Fail if `bin/` directory exists but is empty.
          [ -z "$bins" ] && exit 1

          echo "$bins" | sed -E 's#\./##'
        '';
      };

      # Output a single bin name, if package only containts one bin, and that the name of that bin
      # differs from the package's `name` or `pname`, which would cause `nix run` to fail.
      get-maingrog-candidates = writeShellApplication {
        name = "get-maingrog-candidates";
        runtimeInputs = [ get-bins-in-store ] ++ attrValues { inherit (pkgs) jq ripgrep; };
        text = ''
          pkg_info="$1" # output of `get-pkg-info`
          nixpkgs="$2"

          attr_name=$(echo "$pkg_info" | jq -r '.attrName')
          name=$(echo "$pkg_info" | jq -r '.name')
          pname=$(echo "$pkg_info" | jq -r '.pname')
          store_path=$(echo "$pkg_info" | jq -r '.storePath')

          bins=$(get-bins-in-store "$store_path" "$attr_name" "$nixpkgs")

          # Fail if any executables match the packages `name` or `pname`.
          echo "$bins" | rg '^('"$name"'|'"$pname"')$' > /dev/null && exit 1

          # Filter out wrapped bins since we don't care about them.
          echo "$bins" | rg --invert-match '.*-wrapped'
        '';
      };


      # Helper scripts to insert mainProgram into files --------------------------------------------

      # Insert a `mainProgram` line into a file containing a package definition.
      #
      # Note that insertions by this script might sometimes cause syntax errors, particularly if
      # the meta attribute `mainProgram` is to be inserted below isn't defined on a single line.
      write-mainprog-line = writeShellApplication {
        name = "write-mainprog-line";
        runtimeInputs = attrValues { inherit (pkgs) gnugrep gnused; };
        text = ''
          bin="$1"
          pkg_info="$2" # output of `get-pkg-info`

          insert_info=$(echo "$pkg_info" | jq -r '.editPositionInfo')
          file=$(echo "$insert_info" | jq -r '.file')
          line=$(echo "$insert_info" | jq -r '.line')
          meta_attr=$(echo "$insert_info" | jq -r '.metaAttr')

          # Fail if insertion point is isn't specific to the given package.
          echo "$file" | grep 'perl-modules/generic' > /dev/null && exit 1

          if echo "$file" | grep 'node-packages' > /dev/null; then
            name=$(echo "$pkg_info" | jq -r '.name' | sed -E 's#_at_(.+)_slash_(.+)#"@\1/\2"#')
            sed -i "$line a\\
          $name = \"$bin\";" "$file"
          else
            indent=$(sed -n "$line p" "$file" | sed -E 's/^( +)'"$meta_attr"'.*/\1/')
            sed -i "$line a\\
        ''${indent}mainProgram = \"$bin\";" "$file"
          fi
        '';
      };

      # Check whether package is a candidate for adding `meta.mainProgram` and if it is, attempt to
      # insert in into the appropriate file.
      add-mainprog = writeShellApplication {
        name = "add-mainprog";
        runtimeInputs = [
          get-maingrog-candidates
          write-mainprog-line
        ] ++ attrValues { inherit (pkgs) coreutils gnugrep gnused jq; };
        text = ''
          pkg_info="$1" # output of `get-pkg-info`
          nixpkgs="$2"

          attr_name=$(echo "$pkg_info" | jq -r '.attrName')

          # Skip if packages already has meta.mainProgram defined.
          if [ -n "$(echo "$pkg_info" | jq -r '.mainProgram')" ]; then
            echo "Package '$attr_name' already has meta.mainProgram defined"
            exit 0
          fi

          # Skip if package is defined in a file where auto-insertion doesn't make sense, e.g.,
          # cases where package derivation is auto-generated, and there isn't an established way to
          # define `meta.mainProgram` (like there is for `nodePackages`).
          file=$(echo "$pkg_info" | jq -r '.position' | sed -E 's/(.+):[0-9]+/\1/')
          echo "$file" | grep 'haskell-modules' > /dev/null && exit 0

          bins=$(get-maingrog-candidates "$pkg_info" "$nixpkgs") || exit 0

          # Skip if there is more than one executable for package
          [ "$(echo "$bins" | wc -l)" = "1" ] || exit 0

          # Attempt to insert `mainProgram` line into the file where package is defined, and if
          # insertion fails, print a message with info to help guide the user to insert in manually.
          if write-mainprog-line "$bins" "$pkg_info"; then
            echo "Added '$bins' as meta.mainProgram for package '$attr_name'"
          else
            echo ""
            echo "Failed to add '$bins' as meta.mainProgram for '$attr_name' in:"
            echo "$file"
            echo ""
          fi
        '';
      };


      # Other helper scripts -----------------------------------------------------------------------

      # Given a package that has `meta.mainProgram` defined, remove the `meta.mainProgram`
      # definition if the packages `name` or `pname` match `meta.mainProgram`, or the package
      # doesn't provide a bin that matches `meta.mainProgram`.
      #
      # Note that this script may remove `meta.mainProgram` in cases where it shouldn't, e.g.,
      # cases where multiple packages share a derivation or meta attribute set, where one of the
      # package's `name` or `pname` match the name of an executable provided by the derivation.
      remove-invalid-mainprog = writeShellApplication {
        name = "remove-invalid-mainprog";
        runtimeInputs = [
          get-bins-in-store
          nix-store-ls
        ] ++ attrValues { inherit (pkgs) gnused jq ripgrep; };
        text = ''
          pkg_info="$1" # output of `get-pkg-info`
          nixpkgs="$2"

          attr_name=$(echo "$pkg_info" | jq -r '.attrName')
          mainprog=$(echo "$pkg_info" | jq -r '.mainProgram')

          # Skip if package doesn't have a `meta.mainProgram` defined.
          if [ -z "$mainprog" ]; then
            echo "Package '$attr_name' doesn't have meta.mainProgram defined"
            exit 0
          fi

          delete_info=$(echo "$pkg_info" | jq -r '.editPositionInfo')
          file=$(echo "$delete_info" | jq -r '.file')
          line=$(echo "$delete_info" | jq -r '.line')

          attr_name=$(echo "$pkg_info" | jq -r '.attrName')
          name=$(echo "$pkg_info" | jq -r '.name')
          pname=$(echo "$pkg_info" | jq -r '.pname')
          store_path=$(echo "$pkg_info" | jq -r '.storePath')

          bins=$(get-bins-in-store "$store_path" "$attr_name" "$nixpkgs" || echo "")

          if echo "$bins" | rg '^('"$name"'|'"$pname"')$' > /dev/null; then

            removal_reason="an executable matched name or pname"

          elif echo "$bins" | rg "$mainprog" > /dev/null; then exit 0

          elif [ -n "$bins" ]; then

            removal_reason="no executables named '$mainprog'"

          elif nix-store-ls daemon "$store_path" > /dev/null \
            || nix-store-ls https://cache.nixos.org "$store_path" > /dev/null; then

            removal_reason="package has no executables"

          else

            echo "Failed to query store path for '$attr_name': package probably failed to build"
            exit 0

          fi

          echo "Removing meta.mainProgram for '$attr_name': $removal_reason"
          sed -i "$line d" "$file"
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
            -f ${./lib/package-names.nix} output \
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
            -f ${./lib/package-info.nix} output \
              | jq -c
        '';
      };

      add-missing-mainprogs = writeShellApplication {
        name = "add-missing-mainprogs";
        runtimeInputs = [ add-mainprog get-pkg-info get-pkg-names ];
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]

          for pkg_name in $(get-pkg-names "$nixpkgs" "$pkg_set_attr_path" false true); do
            add-mainprog "$(get-pkg-info "$nixpkgs" "$pkg_set_attr_path" "$pkg_name")" "$nixpkgs"
          done
        '';
      };

      find-candidate-mainprogs = writeShellApplication {
        name = "find-candidate-mainprogs";
        runtimeInputs = [
          get-maingrog-candidates
          get-pkg-info
          get-pkg-names
        ] ++ attrValues { inherit (pkgs) jq; };
        text = ''
          nixpkgs="$1"           # path to local nixpkgs
          pkg_set_attr_path="$2" # e.g., [ "perlPackages" ] or [ "pkgs" ]

          for pkg_name in $(get-pkg-names "$nixpkgs" "$pkg_set_attr_path" false true); do
            pkg_info=$(get-pkg-info "$nixpkgs" "$pkg_set_attr_path" "$pkg_name")
            attr_name=$(echo "$pkg_info" | jq -r '.attrName')
            file=$(echo "$pkg_info" | jq -r '.editPositionInfo.file')

            bins=$(get-maingrog-candidates "$pkg_info" "$nixpkgs") || continue

            echo "Candidate mainPrograms for '$attr_name':"
            echo "$bins"
            echo "Add in: $file"
            echo ""
          done
        '';
      };

      remove-invalid-mainprogs = writeShellApplication {
        name = "remove-invalid-mainprogs";
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
          add-missing-mainprogs
          find-candidate-mainprogs
          remove-invalid-mainprogs;

        default = add-missing-mainprogs;
      };
    }
  );
}

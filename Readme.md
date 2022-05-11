# Overview

This WIP project houses the hacky scripts that I use to help with the maintenance of [`meta.mainProgram`](https://nixos.org/manual/nixpkgs/stable/#var-meta-mainProgram) attributes for packages in `nixpkgs`, with the goal of increasing the number of packages that function with `nix run`.

## Scripts

Currently the project provides the following main scripts:

* `add-missing-mainprogs`
* `add-missing-mainprogs-ocaml`
* `add-missing-mainprogs-python`
* `add-missing-mainprogs-top-level`
* `print-missing-mainprogs-node`
* `print-missing-mainprogs-perl`

All take one argument, a path to `nixpkgs` on the local system.

Each identify packages that don't have `meta.mainProgram` defined, and provide a single executable who's name differs from the package's `name` or `pname`.

The `add-missing-mainprogs` script does this for all packages in `ocamlPackages`, `python{2,3}Packages`, and top-level packages, then attempts to add `meta.mainProgram` to the file where the package's derivation is defined, and if it fails, prints an error message with the information required to try and add it manually.

Due to the auto-generated nature of packages in `nodePackages`, `meta.mainProgram` needs to be added using overrides making automatic insertion more complicated. Therefore the `print-missing-mainprogs-node` script outputs the info that should be added to `pkgs/development/node-packages/default.nix`.

The `print-missing-mainprogs-perl` script does the same for packages in `perlPackages` where automatic insertion is more challenging due to all the packages being defined in one large file.

## Future development

Future work will likely focus on expanding to more non-top-level package collections in `nixpkgs`, as well as adding the ability to validate `meta.mainProgram` definitions for packages.

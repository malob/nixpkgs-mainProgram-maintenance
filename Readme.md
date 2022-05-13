# Overview

This WIP project houses the hacky scripts that I use to help with the maintenance of [`meta.mainProgram`](https://nixos.org/manual/nixpkgs/stable/#var-meta-mainProgram) attributes for packages in `nixpkgs`, with the goal of increasing the number of packages that function with `nix run`.

## Scripts

Currently the project provides 3 main scripts:

* `add-missing-mainprogs`
* `print-missing-mainprogs-node`
* `print-missing-mainprogs-perl`

All take a path to `nixpkgs` on the local system as their first argument, and each identify packages that don't have `meta.mainProgram` defined that provide a single executable who's name differs from the package's `name` or `pname`.

The `add-missing-mainprogs` script takes the name of a package set in `nixpkgs` (e.g., `pkgs` for all top-level packages, or `python39Packages`, etc.) or `all` as the second argument, and attempts to add `meta.mainProgram` for all packages of the given package set. If it fails, it prints a message with the information required to try and add it manually in the appropriate file. If `all` is given as the second argument it will attempt to do this for packages in `ocamlPackages`, `python39Packages`, and all top-level packages.

Due to the auto-generated nature of packages in `nodePackages`, `meta.mainProgram` needs to be added using overrides making automatic insertion more complicated. Therefore the `print-missing-mainprogs-node` script outputs the lines that should be added to `pkgs/development/node-packages/main-programs.nix` (which will be added when PR #171863 is merged in `NixOS/nixpkgs`).

The `print-missing-mainprogs-perl` script does the same for packages in `perlPackages` where automatic insertion is more challenging due to all the packages being defined in one large file (`pkgs/top-level/perl-packages.nix`).

## Future development

Future work will likely focus on expanding to more non-top-level package collections in `nixpkgs`, improving auto-inserting capability, as well as adding the ability to validate `meta.mainProgram` definitions for packages.

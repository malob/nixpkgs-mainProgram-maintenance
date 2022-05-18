# Overview

This WIP project houses the hacky (but increasingly less so) scripts that I use to help with the maintenance of [`meta.mainProgram`](https://nixos.org/manual/nixpkgs/stable/#var-meta-mainProgram) attributes for packages in `nixpkgs`, with the goal of increasing the number of packages that function with `nix run`.

Currently the project provides 2 primary scripts:

* `add-mps`
* `add-mps-interactive`
* `rm-mps`

Both of which take two arguments, a path to `nixpkgs` on the local system, and an attribute path to a package set in `nixpkg`, e.g., `'[ "perlPackages" ]'`.

## `add-mps`

Usage examples:

```
nix run .#add-mps -- ~/Code/nixpkgs '[ "pkgs" ]'

# or since it's the default package

nix run . -- ~/Code/nixpkgs '[ "pkgs" ]'
```

The `add-mps` script finds all packages in the given package set that _don't have_ `meta.mainProgram` defined and then:

1. Checks whether the official binary cache contains the store path for each package using `nix store ls`; and
   * if it does, it retrieves the names of all executables located in `bin/`;
   * otherwise, it uses `hydra check` to see if the package failed to build on Hydra; and
     * if it didn't, and the store path for the package isn't listed in `failed-builds.txt`, it builds the package locally; and
       * if it succeeds, it retrieves the names of all executables located in `bin/`;
       * otherwise, it appends the store path of the package to `failed-builds.txt`.
2. If a single executable was found, and the name of that executable differs from the packages `name` (more specifically the result of `builtins.parseDrvName name`) or `pname`, it attempts to insert a `meta.mainProgram` definition into the appropriate file; and
   * if is succeeds, it prints a message to that effect;
   * otherwise, it prints a message with info helpful for trying to insert the `meta.mainProgram` definition manually.

Known issues:

* The meta attribute under which the script attempts to insert the `meta.mainProgam` definition spans multiple lines. In this case the script will insert the `meta.mainProgam` definition on the incorrect line producing a syntax error in the file.
* The meta attribute under which the script inserts the `meta.mainProgam` definition is in a meta block shared by unrelated packages. For example, it used to be the case that for packages in for `perlPackages`, if the package didn't have meta attributes defined, the script would insert the `meta.mainProgam` definition into `pkgs/development/perl-modules/generic/default.nix`, which applies to all packages in `perlPackages`. This case is now handled, but there are likely others that aren't.
* If the package definition is auto-generated, the inserted `meta.mainProgram` definition won't be helpful since it will be overwritten the next time the package definitions are generated. Exceptions are `haskellPackages` which the script explicitly skips, and `nodePackages` which has it's own mechanism for adding `meta.mainProgram` definitions which this script knows how to handle.
* Sometimes the executables available for a package differ between platforms, e.g., `docker-credential-helpers` provides a single executable on Darwin but multiple executables on Linux.
* Sometimes the name of an executable changes based on the packages definition. The most common example of this is when the executables name includes the specific version of the package. In these cases the `meta.mainProgram` definition should be manually edited to ensure it remains correct, e.g., `mainProgram = "foo_${version}";`.
* Sometimes a package includes a single executable whose name differs from the packages `name` or `pname`, but it really doesn't make sense at all for that executable the be the thing that would be run if someone tried to `nix run` the package. In these cases, the package should be added to `pkgs-to-skip` in [lib/package-names.nix](./lib/package-names.nix).

As such, always make sure you review the changes made by this script to ensure they are valid. One way to catch problematic additions of `meta.mainProgram` definitions by this script, is to run `rm-mps` after running `add-mps`.

## `add-mps-interactive`

The `add-mps-interactive` does the same thing as `add-mps` up to step up to step 2., at which point it presents a selection prompt (if executables where found, and none of them matched the pacakge's `name` or `pname`), that list all executables found as well as "Skip" and "Exclude". If the user selects,

* one of the listed binaries, it then attempts to insert the `meta.mainProgram` definition into the appropriate file;
* "Skip", it does nothing an moves onto the next package;
* "Exclude", it adds an entry to [lib/package-to-skip.nix](./lib/package-to-skip.nix) for the package, which will cause that package to be excluded from future runs of the scripts in this project.


## `rm-mps`

Usage example:

```
nix run .#rm-mps -- ~/Code/nixpkgs '[ "pkgs" ]'
```

The `rm-mps` script finds all packages in the given package set that _have_ `meta.mainProgram` defined and then,

1. it attempts to finds all executables provided for each package in the same way as `add-mps`; and
2. if it could query the store path for the package; and
   * one of the following conditions is met:
     * the `bin/` directory doesn't exist;
     * the `bin/` directory is empty;
     * one of the executables in `bin/` match the package's `name` or `pname`; or
     * none of the executables in `bin/` match the defined `mainProgram`;
   * the `meta.mainProgram` line for the package is removed form the appropriate file.

Known issues:

* Sometimes multiple variations of packages exist in `nixpkgs` that are generated by, e.g., overriding a particular package, or calling a function that generates the package derivation with different arguments. In these cases, sometimes one of the packages' `name` or `pname` match an executable found in the `bin/` triggering the removal of the `meta.mainProgram` for that package, which due to it being shared with other packages who's `name` or `pname` don't match for some reason, would cause those packages to stop working with `nix run`.

As such, always make sure you review the changes made by this script to ensure they are valid.

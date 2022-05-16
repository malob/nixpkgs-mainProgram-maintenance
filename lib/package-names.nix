{ nixpkgs
, system ? builtins.currentSystem
, config ? { allowUnfree = true; }
, pkgSetAttrPath ? [ "pkgs" ]
, includePkgsWithMainProgram
, includePkgsWoMainProgram
}:

let
  pkgs = import nixpkgs { inherit config system; };
  inherit (builtins) attrNames elem tryEval;
  inherit (pkgs.lib) getAttrFromPath filterAttrs isDerivation pipe;

  pkgs-to-skip = [
    # Single bins really aren't a sensible mainProgram
    [ "perlPackages" "AlienSDL" ]
    [ "perlPackages" "DevelCheckOS" ]
    [ "perlPackages" "DevelChecklib" ]
    [ "perlPackages" "libapreq2" ]
  ];

  filterPredicate = n: p:
    (!(elem (pkgSetAttrPath ++ [ n ]) pkgs-to-skip)) &&
    (tryEval p).success &&
    (isDerivation p) &&
    (
      ((p ? meta.mainProgram) && includePkgsWithMainProgram) ||
      ((!(p ? meta.mainProgram)) && includePkgsWoMainProgram)
    ) &&
    (tryEval p.name).success &&
    (tryEval p.outPath).success &&
    (p ? meta.position);
in
{
  output = pipe pkgs [ (getAttrFromPath pkgSetAttrPath) (filterAttrs filterPredicate) attrNames ];
}


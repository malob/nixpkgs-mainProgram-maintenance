{ nixpkgs, system }:

let
  pkgs = import nixpkgs { inherit system; };
  inherit (builtins) attrValues filter parseDrvName tryEval;
  inherit (pkgs.lib) isDerivation;

  # Predicates
  isValidPkg = p:
    (tryEval p).success &&
    (isDerivation p) &&
    (tryEval p.name).success &&
    (tryEval p.outPath).success &&
    (p ? meta.position);
  hasMainProg = p: p ? meta.mainProgram;

  # Utility functions
  getPkgs = attrSet: filter isValidPkg (attrValues attrSet);
  getPkgsWithMainProg = attrSet: filter hasMainProg (getPkgs attrSet);
  getPkgsWoMainProg = attrSet: filter (x: !(hasMainProg x)) (getPkgs attrSet);

  getPkgInfo = p: rec {
    inherit (parseDrvName p.name) name;
    pname = p.pname or name;
    inherit (p.meta) position;
    storePath = p.outPath;
    mainProgram = p.meta.mainProgram or "";
  };

  mkPkgInfoAttrSet = name: attrSet: {
    ${name} = {
      w-mainprog = map getPkgInfo (getPkgsWithMainProg attrSet);
      wo-mainprog = map getPkgInfo (getPkgsWoMainProg attrSet);
    };
  };
in
mkPkgInfoAttrSet "top-level" pkgs //
mkPkgInfoAttrSet "node" pkgs.nodePackages //
mkPkgInfoAttrSet "ocaml" pkgs.ocamlPackages //
mkPkgInfoAttrSet "perl" pkgs.perlPackages //
mkPkgInfoAttrSet "python2" pkgs.python2Packages //
mkPkgInfoAttrSet "python3" pkgs.python3Packages

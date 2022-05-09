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
  hasMainProgram = p: p ? meta.mainProgram;

  # Utility functions
  getPkgInfo = p: rec {
    inherit (parseDrvName p.name) name;
    pname = p.pname or name;
    inherit (p.meta) position;
    storePath = p.outPath;
    mainProgram = p.meta.mainProgram or "";
  };
  getPkgs = attrSet: filter isValidPkg (attrValues attrSet);
  getPkgsWithMainProgram = attrSet: filter hasMainProgram (getPkgs attrSet);
  getPkgsWoMainProgram = attrSet: filter (x: !(hasMainProgram x)) (getPkgs attrSet);
in
{
  topLevelPkgs = {
    withMainProgram = map getPkgInfo (getPkgsWithMainProgram pkgs);
    woMainProgram = map getPkgInfo (getPkgsWoMainProgram pkgs);
  };

  nodePackages = {
    withMainProgram = map getPkgInfo (getPkgsWithMainProgram pkgs.nodePackages);
    woMainProgram = map getPkgInfo (getPkgsWoMainProgram pkgs.nodePackages);
  };
}

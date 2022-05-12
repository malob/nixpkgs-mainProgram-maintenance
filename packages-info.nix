{ nixpkgs, system }:

let
  pkgs = import nixpkgs { inherit system; };
  inherit (builtins) attrValues filter parseDrvName tryEval unsafeGetAttrPos;
  inherit (pkgs.lib) filterAttrs mapAttrsToList isDerivation;

  # Predicates
  isValidPkg = p:
    (tryEval p).success &&
    (isDerivation p) &&
    (tryEval p.name).success &&
    (tryEval p.outPath).success &&
    (p ? meta.position);
  hasMainProg = p: p ? meta.mainProgram;

  # Utility functions
  getPkgs = filterAttrs (_: isValidPkg);
  getPkgsWithMainProg = attrSet: filterAttrs (_: hasMainProg) (getPkgs attrSet);
  getPkgsWoMainProg = attrSet: filterAttrs (_: x: !(hasMainProg x)) (getPkgs attrSet);

  # getMainprogInsertionPoint = p:
  #   if p.meta.maintainers or null != null
  #   then builtins.unsafeGetAttrPos "maintainers" p.meta
  #   else if p.meta.license or null != null
  #   then builtins.unsafeGetAttrPos "license" p.meta
  #   else if p.meta.homepage or null != null
  #   then builtins.unsafeGetAttrPos "homepage" p.meta
  #   else if p.meta.description or null != null
  #   then builtins.unsafeGetAttrPos "description" p.meta
  #   else null;

  getPkgInfo = pkgSet: n: p: rec {
    attrName = "${pkgSet}.${n}";
    inherit (parseDrvName p.name) name;
    pname = p.pname or name;
    inherit (p.meta) position;
    storePath = p.outPath;
    mainProgram = p.meta.mainProgram or "";
  };

  mkPkgInfoAttrSet = pkgSet: {
    ${pkgSet} = {
      w-mainprog = mapAttrsToList (getPkgInfo pkgSet) (getPkgsWithMainProg pkgs.${pkgSet});
      wo-mainprog = mapAttrsToList (getPkgInfo pkgSet) (getPkgsWoMainProg pkgs.${pkgSet});
    };
  };
in
mkPkgInfoAttrSet "pkgs" //
mkPkgInfoAttrSet "nodePackages" //
mkPkgInfoAttrSet "ocamlPackages" //
mkPkgInfoAttrSet "perlPackages"  //
mkPkgInfoAttrSet "python2Packages" //
mkPkgInfoAttrSet "python3Packages"

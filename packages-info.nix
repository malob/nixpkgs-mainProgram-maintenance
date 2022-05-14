{ nixpkgs, system, pkgSetName }:

let
  pkgs = import nixpkgs { inherit system; config = { allowUnfree = true;}; };
  inherit (builtins) attrValues elem filter parseDrvName tryEval unsafeGetAttrPos;
  inherit (pkgs.lib) filterAttrs mapAttrsToList isDerivation;

  pkgs-to-skip = [
    # Single bins really aren't a sensible mainProgram
    "perlPackages.AlienSDL"
    "perlPackages.DevelCheckOS"
    "perlPackages.DevelChecklib"
    "perlPackages.libapreq2"
  ];

  isValidPkg = n: p:
    (!(elem "${pkgSetName}.${n}" pkgs-to-skip))
    && (tryEval p).success
    && (isDerivation p)
    && (tryEval p.name).success
    && (tryEval p.outPath).success
    && (p ? meta.position);

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

  getPkgsInfo = n: p: rec {
    attrName = "${pkgSetName}.${n}";
    inherit (parseDrvName p.name) name;
    pname = p.pname or name;
    inherit (p.meta) position;
    storePath = p.outPath;
    mainProgram = p.meta.mainProgram or "";
  };

  all-pkgs-info = mapAttrsToList getPkgsInfo (filterAttrs isValidPkg pkgs.${pkgSetName});
in
{
  all = all-pkgs-info;
  w-mainprog = filter (x: x.mainProgram != "") all-pkgs-info;
  wo-mainprog = filter (x: x.mainProgram == "") all-pkgs-info;
}

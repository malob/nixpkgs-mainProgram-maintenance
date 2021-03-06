{ nixpkgs
, system ? builtins.currentSystem
, config ? { allowUnfree = true;}
, pkgSetAttrPath ? [ "pkgs" ]
, pkgName
}:

let
  pkgs = import nixpkgs { inherit config system; };
  inherit (builtins) elem isAttrs parseDrvName unsafeGetAttrPos;
  inherit (pkgs.lib) concatStringsSep getAttrFromPath foldl;

  getMetaAttrPosition = p: metaAttrName:
  if (p ? meta.${metaAttrName})
  then (builtins.unsafeGetAttrPos metaAttrName p.meta) // { meta_attr = metaAttrName; }
  else null;

  getEditPositionInfo = p:
    if elem pkgSetAttrPath [ [ "nodePackages" ] [ "nodePackages_latest" ] ] then {
      file = "${nixpkgs}/pkgs/development/node-packages/main-programs.nix";
      line = 3;
    }
    else if (p ? meta.mainProgram) then
      getMetaAttrPosition p "mainProgram"
    else foldl (b: a: if isAttrs b then b else getMetaAttrPosition p a) null [
      "maintainers"
      "license"
      "changelog"
      "downloagPage"
      "homepage"
      "branch"
      "description"
    ];

  getPkgInfo = p: rec {
    attr_name = "${concatStringsSep "." pkgSetAttrPath }.${pkgName}";
    inherit (parseDrvName p.name) name;
    pname = p.pname or name;
    inherit (p.meta) position;
    store_path = p.outPath;
    edit_info = getEditPositionInfo p;
    main_program = p.meta.mainProgram or null;
    inherit nixpkgs;
  };
in
{
  output = getPkgInfo (getAttrFromPath pkgSetAttrPath pkgs).${pkgName};
}

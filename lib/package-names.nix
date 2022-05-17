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
    # Have single bins that really aren't a sensible mainProgram
    [ "perlPackages" "AlienSDL" ]
    [ "perlPackages" "DevelCheckOS" ]
    [ "perlPackages" "DevelChecklib" ]
    [ "perlPackages" "libapreq2" ]

    # Have multiple bins, none of which should obviously be blessed as mainProgram
    [ "perlPackages" "Clipboard" ]
    [ "perlPackages" "ConvertUU" ]
    [ "perlPackages" "DBI" ]
    [ "perlPackages" "DateManip" ]
    [ "perlPackages" "Deliantra" ]
    [ "perlPackages" "DevelNYTProf" ]
    [ "perlPackages" "FileMimeInfo" ]
    [ "perlPackages" "GooCanvas" ]
    [ "perlPackages" "HTMLFormFu" ]
    [ "perlPackages" "HTMLMason" ]
    [ "perlPackages" "LWP" ]
    [ "perlPackages" "LWPUserAgent" ]
    [ "perlPackages" "MP3Tag" ]
    [ "perlPackages" "MathPrimeUtil" ]
    [ "perlPackages" "MaxMindDBReader" ]
    [ "perlPackages" "ModuleCPANfile" ]
    [ "perlPackages" "NetIP" ]
    [ "perlPackages" "OpenOfficeOODoc" ]
    [ "perlPackages" "PerconaToolkit" ]
    [ "perlPackages" "Razor2ClientAgent" ]
    [ "perlPackages" "SOAPLite" ]
    [ "perlPackages" "TAPParserSourceHandlerpgTAP" ]
    [ "perlPackages" "TemplateToolkit" ]
    [ "perlPackages" "TextBibTeX" ]
    [ "perlPackages" "TextNSP" ]
    [ "perlPackages" "TextPDF" ]
    [ "perlPackages" "TextRecordParser" ]
    [ "perlPackages" "Tk" ]
    [ "perlPackages" "VMEC2" ]
    [ "perlPackages" "XMLEncoding" ]
    [ "perlPackages" "XMLRules" ]
    [ "perlPackages" "YAMLPP" ]
    [ "perlPackages" "cam_pdf" ]
    [ "perlPackages" "maatkit" ]
    [ "perlPackages" "podlators" ]

    [ "nodePackages" "code-theme-converter" ]
    [ "nodePackages" "hs-client" ]
    [ "nodePackages" "ijavascript" ]
    [ "nodePackages" "manta" ]
    [ "nodePackages" "nijs" ]
    [ "nodePackages" "smartdc" ]
    [ "nodePackages" "vega-cli" ]
    [ "nodePackages" "vega-lite" ]
    [ "nodePackages" "vscode-langservers-extracted" ]
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


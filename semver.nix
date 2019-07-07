{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
}:

let
  # Replace a list entry at defined index with set value
  replaceIdx = idx: value: list: (
    lib.sublist 0 idx list ++
    [ value ] ++
    lib.sublist (idx + 1) ((lib.length) list + 1) list);

  operators = let
    mkComparison = returns: comp: v: builtins.elem (comp v) returns;
    mkIdxComparison = idx: comp: v: let
      ver = builtins.splitVersion v;
      minor = builtins.toString (lib.toInt (builtins.elemAt ver idx) + 1);
      upper = builtins.concatStringsSep "." (replaceIdx idx minor ver);
    in operators.">=" comp v && operators."<" comp upper;
  in {
    "==" = mkComparison [ 0 ];
    ">=" = mkComparison [ 0 1 ];
    "<=" = mkComparison [ (-1) 0 ];
    ">" = mkComparison [ 1 ];
    "<" = mkComparison [ (-1) ];
    "!=" = mkComparison [ (-1) 1 ];
    "~" = mkIdxComparison 1;
    "^" = mkIdxComparison 0;
  };

  parseConstraint = constraintStr: let
    m = builtins.match "([=><!~\^]+)([0-9\.\*]+)" constraintStr;
    elemAt = builtins.elemAt m;
  in { op = elemAt 0; v = elemAt 1; };

  satisfies = version: constraint: let
    inherit (parseConstraint constraint) op v;
    comp = builtins.compareVersions version;
  in operators."${op}" comp v;

in { inherit parseConstraint satisfies; }

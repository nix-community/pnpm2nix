{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
}:

let
  # Replace a list entry at defined index with set value
  replaceIdx = idx: value: list: lib.sublist 0 idx list ++
    [ value ] ++
    lib.sublist (idx + 1) ((builtins.length) list + 1) list;

  operators = let
    matchWildCard = s: builtins.match "(.*)${re.wildcard}" s;
    mkComparison = returns: version: v: builtins.elem (builtins.compareVersions version v) returns;
    mkIdxComparison = idx: version: v: let
      ver = builtins.splitVersion v;
      minor = builtins.toString (lib.toInt (builtins.elemAt ver idx) + 1);
      upper = builtins.concatStringsSep "." (replaceIdx idx minor ver);
    in operators.">=" version v && operators."<" version upper;
    # For most operations it's sufficient to drop precision for wildcard matches
    dropWildcardPrecision = f: version: constraint: let
      m = matchWildCard constraint;
      hasWildcard = m != null;
      c = if hasWildcard then (builtins.elemAt m 0) else constraint;
      v =
        if hasWildcard then (builtins.substring 0 (builtins.stringLength c) version)
        else version;
    in f v c;
  in {
    # Prefix operators
    "==" = dropWildcardPrecision (mkComparison [ 0 ]);
    ">" = dropWildcardPrecision (mkComparison [ 1 ]);
    "<" = dropWildcardPrecision (mkComparison [ (-1) ]);
    "!=" = v: c: ! operators."==" v c;
    ">=" = v: c: operators."==" v c || operators.">" v c;
    "<=" = v: c: operators."==" v c || operators."<" v c;
    # Special prefix operators (expands to other operations)
    "~" = mkIdxComparison 1;
    "^" = mkIdxComparison 0;
    # Infix operators
    "-" = version: v: operators.">=" version v.vl && operators."<=" version v.vu;
  };

  # Reusable regex components
  re = {
    operators = "([=><!~\^]+)";
    version = "([0-9\.\*x]+)";
    wildcard = "(\.[x\*])";
  };

  parseConstraint = constraintStr: let
    # The common prefix operators
    mPre = builtins.match "${re.operators} *${re.version}" constraintStr;
    # There is also an infix operator to match ranges
    mIn = builtins.match "${re.version} *(-) *${re.version}" constraintStr;
  in (
    if mPre != null then {
      op = builtins.elemAt mPre 0;
      v = builtins.elemAt mPre 1;
    }
    # Infix operators are range matches
    else if mIn != null then {
      op = builtins.elemAt mIn 1;
      v = {
        vl = (builtins.elemAt mIn 0);
        vu = (builtins.elemAt mIn 2);
      };
    }
    else throw "Constraint \"${constraintStr}\" could not be parsed");

  satisfies = version: constraint: let
    inherit (parseConstraint constraint) op v;
  in operators."${op}" version v;

in { inherit satisfies; }

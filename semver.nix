{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:

let
  inherit (builtins) elemAt match;

  # Replace a list entry at defined index with set value
  ireplace = idx: value: list: let
    inherit (builtins) genList length;
  in
  genList (i: if i == idx then value else (elemAt list i)) (length list);

  operators = let
    mkComparison = ret: version: v:
    let
      x = 1;
    in
    builtins.compareVersions version v == ret;

    mkIdxComparison = idx: version: v: let
      ver = builtins.splitVersion v;
      minor = builtins.toString (lib.toInt (elemAt ver idx) + 1);
      upper = builtins.concatStringsSep "." (ireplace idx minor ver);
    in
    operators.">=" version v && operators."<" version upper;

    dropWildcardPrecision = f: version: constraint: let
      # TODO: some stricter trailing-wildcard matching
      wildcardMatch = match "(.*?)([0-9]\\.[0-9]\\.[0-9]|[0-9]\\.[0-9]|[0-9])?([.x*]*)" constraint;
      matchPart = (elemAt wildcardMatch 1);
      shortConstraint = if matchPart != null then matchPart else "";
      shortVersion = builtins.substring 0 (builtins.stringLength shortConstraint) version;
    in
    f shortVersion shortConstraint;
  in {
    # Prefix operators
    "==" = dropWildcardPrecision (mkComparison 0);
    ">" = dropWildcardPrecision (mkComparison 1);
    "<" = dropWildcardPrecision (mkComparison (-1));
    "!=" = v: c: ! operators."==" v c;
    ">=" = v: c: operators."==" v c || operators.">" v c;
    "<=" = v: c: operators."==" v c || operators."<" v c;
    # Semver specific operators
    "~" = mkIdxComparison 1;  #
    "^" = mkIdxComparison 0;
  };

  re = {
    operators = "([=><!~^]+)";
    version = "([0-9.*x]+|[0-9.*x]+-[a-z0-9]+)";
  };

  parseConstraint = constraintStr: let
    # The common prefix operators
    mPre = match "${re.operators} *${re.version}" constraintStr;
    # There is an upper bound to the operator (this implementation is a bit hacky)
    mUpperBound = match "${re.operators} *${re.version} *< *${re.version}" constraintStr; 
    # There is also an infix operator to match ranges
    mIn = match "${re.version} - *${re.version}" constraintStr;
    # There is no operators
    mNone = match "${re.version}" constraintStr;
  in (
    if mPre != null then {
      ops.t = elemAt mPre 0;
      v = elemAt mPre 1;
    }
    # Infix operators are range matches
    else if mIn != null then {
      ops = {
        t = "-";
        l = ">=";
        u = "<=";
      };
      v = {
        vl = (elemAt mIn 0);
        vu = (elemAt mIn 1);
      };
    }
    else if mUpperBound != null then {
      ops = {
        t = "-";
        l = (elemAt mUpperBound 0);
        u = "<";
      };
      v = {
        vl = (elemAt mUpperBound 1);
        vu = (elemAt mUpperBound 2);
      };
    }
    else if mNone != null then {
      ops.t = "==";
      v = elemAt mNone 0;
    }
    else throw "Constraint \"${constraintStr}\" could not be parsed");

  satisfiesSingle = version: constraint:
  let
    inherit (parseConstraint constraint) ops v;
  in
  if ops.t == "-" then
    (operators."${ops.l}" version v.vl && operators."${ops.u}" version v.vu)
  else
    operators."${ops.t}" version v;

  satisfies = version: constraint:
    # TODO: use a regex for the split
    builtins.length (builtins.filter (c: satisfiesSingle version c) (lib.splitString " || " constraint)) > 0;

in { inherit satisfies; }

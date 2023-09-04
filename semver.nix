{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:
let
  inherit (builtins) elemAt match;

  # Replace a list entry at defined index with set value
  ireplace = idx: value: list:
    let
      inherit (builtins) genList length;
    in genList (i: if i == idx then value else (elemAt list i)) (length list);

  orBlank = x: if x != null then x else "";

  operators = let
    mkComparison = ret: version: v:
      let
        x = 1;
      in builtins.compareVersions version v == ret;

    mkIdxComparison = idx: version: v:
      let
        ver = builtins.splitVersion v;
        minor = builtins.toString (lib.toInt (elemAt ver idx) + 1);
        upper = builtins.concatStringsSep "." (ireplace idx minor ver);
      in operators.">=" version v && operators."<" version upper;

    dropWildcardPrecision = f: version: constraint:
      let
        wildcardMatch = (
          match
            "([^0-9x*]*)((0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)|(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)|(0|[1-9][0-9]*)){0,1}([.x*]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)){0,1}(\\+([0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)){0,1}"
            constraint
        );
        matchPart = (elemAt wildcardMatch 1);
        shortConstraint = if matchPart != null then matchPart else "";
        shortVersion =
          builtins.substring 0 (builtins.stringLength shortConstraint) version;
      in f shortVersion shortConstraint;
  in {
    # Prefix operators
    "==" = dropWildcardPrecision (mkComparison 0);
    ">" = dropWildcardPrecision (mkComparison 1);
    "<" = dropWildcardPrecision (mkComparison (-1));
    "!=" = v: c: !operators."==" v c;
    ">=" = v: c: operators."==" v c || operators.">" v c;
    "<=" = v: c: operators."==" v c || operators."<" v c;
    # Semver specific operators
    "~" = mkIdxComparison 1;
    "^" = mkIdxComparison 0;
  };

  re = {
    operators = "([=><!~^]+)";
    version =
      "((0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)|(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)|(0|[1-9][0-9]*)){0,1}([.x*]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)){0,1}(\\+([0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)){0,1}";
  };

  reLengths = {
    operators = 1;
    version = 16;
  };

  parseConstraint = constraintStr:
    let
      # The common prefix operators
      mPre = match "${re.operators} *${re.version}" constraintStr;
      # There is an upper bound to the operator (this implementation is a bit hacky)
      mUpperBound =
        match "${re.operators} *${re.version} *< *${re.version}" constraintStr;
      # There is also an infix operator to match ranges
      mIn = match "${re.version} - *${re.version}" constraintStr;
      # There is no operators
      mNone = match "${re.version}" constraintStr;
    in (
      if mPre != null then {
        ops.t = elemAt mPre 0;
        v = orBlank (elemAt mPre reLengths.operators);
      }
        # Infix operators are range matches
      else if mIn != null then {
        ops = {
          t = "-";
          l = ">=";
          u = "<=";
        };
        v = {
          vl = orBlank (elemAt mIn 0);
          vu = orBlank (elemAt mIn reLengths.version);
        };
      } else if mUpperBound != null then {
        ops = {
          t = "-";
          l = (elemAt mUpperBound 0);
          u = "<";
        };
        v = {
          vl = orBlank (elemAt mUpperBound reLengths.operators);
          vu = orBlank (elemAt mUpperBound (reLengths.operators + reLengths.version));
        };
      } else if mNone != null then {
        ops.t = "==";
        v = orBlank (elemAt mNone 0);
      } else
        throw ''Constraint "${constraintStr}" could not be parsed''
    );

  satisfiesSingle = version: constraint:
    let
      inherit (parseConstraint constraint) ops v;
    in if ops.t == "-" then
      (operators."${ops.l}" version v.vl && operators."${ops.u}" version v.vu)
    else
      operators."${ops.t}" version v;

  satisfies = version: constraint:
    builtins.length (
      builtins.filter (c: satisfiesSingle version c)
        (builtins.filter builtins.isString (builtins.split " *\\|\\| *" constraint))
    ) > 0;
in
{ inherit satisfies; }

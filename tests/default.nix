with import (builtins.fetchTarball {
  url = "https://api.github.com/repos/nixos/nixpkgs/tarball/daaa594aa5dc946c3656ec9ef06e80b7068f0904";
  sha256 = "0y8l245w5k0lh0spb3xh956f1lapmr50yf2smqsy03dg47crirb1";
}) { };
with lib.attrsets;

let
  importTest = testFile: (import testFile { inherit pkgs; });

  lolcatjs = importTest ./lolcatjs;
  test-sharp = importTest ./test-sharp;

  mkTest = (name: test: pkgs.runCommandNoCC "${name}" { } (''
    mkdir $out

  '' + test));

in
lib.listToAttrs (map (drv: nameValuePair drv.name drv) [

  # Assert that we set correct version numbers in builds
  (mkTest "assert-version" ''
    if test $(${lolcatjs}/bin/lolcatjs --version | grep "${lolcatjs.version}" | wc -l) -ne 1; then
      echo "Incorrect version attribute! Was: ${lolcatjs.version}, got:"
      ${lolcatjs}/bin/lolcatjs --version
      exit 1
    fi
  '')

  # Make sure we build optional dependencies
  (mkTest "assert-optionaldependencies" ''
    if test $(${lolcatjs}/bin/lolcatjs --help |& grep "Unable to load" | wc -l) -ne 0; then
      echo "Optional dependency missing"
      exit 1
    fi
  '')

  # Test a natively linked overriden dependency
  (mkTest "native-overrides" "${test-sharp}/bin/testsharp")

])

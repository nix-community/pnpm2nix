with (import ((import <nixpkgs> {}).fetchFromGitHub {
  repo = "nixpkgs-channels";
  owner = "NixOS";
  sha256 = "06p37s6ri80z9yp0r6ymjakls1dwqay5xp2cwlymzcyzgaf7g1xg";
  rev = "268d99b1fe4c6066bbdc1b3debf8766dd247c7bf";
}) { });
with lib.attrsets;
with lib;

let
  importTest = testFile: (import testFile { inherit pkgs; });

  pnpm2nix = ../.;

  lolcatjs = importTest ./lolcatjs;
  test-sharp = importTest ./test-sharp;
  test-impure = importTest ./test-impure;
  nested-dirs = importTest ./nested-dirs;

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

  # Test to imupurely build a derivation
  (mkTest "impure" "${test-impure}/bin/testapn")

  (mkTest "python-lint" ''
    echo ${(python2.withPackages (ps: [ ps.flake8 ]))}/bin/flake8 ${pnpm2nix}/
  '')

  # Check if nested directory structures work properly
  (mkTest "nested-dirs" ''
    test -e ${lib.getLib nested-dirs}/node_modules/@types/node || (echo "Nested directory structure does not exist"; exit 1)
  '')

])

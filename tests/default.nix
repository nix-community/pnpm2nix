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
  test-peerdependencies = importTest ./test-peerdependencies;
  test-devdependencies = importTest ./test-devdependencies;
  web3 = importTest ./web3;
  issue-1 = importTest ./issues/1;

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

  # Check if peer dependencies are resolved
  (mkTest "peerdependencies" ''
    winstonPeer=$(readlink -f ${lib.getLib test-peerdependencies}/node_modules/winston-logstash/node_modules/winston)
    winstonRoot=$(readlink -f ${lib.getLib test-peerdependencies}/node_modules/winston)

    test "''${winstonPeer}" = "''${winstonRoot}" || (echo "Different versions in root and peer dependency resolution"; exit 1)
  '')

  # Test a "weird" package with -beta in version number spec
  (let
    web3Drv = lib.elemAt (lib.filter (x: x.name == "web3-1.0.0-beta.30") web3.buildInputs) 0;

  in mkTest "test-beta-names" ''
    test "${web3Drv.name}" = "web3-1.0.0-beta.30" || (echo "web3 name mismatch"; exit 1)
    test "${web3Drv.version}" = "1.0.0-beta.30" || (echo "web3 version mismatch"; exit 1)
  '')

  # Check if checkPhase is being run correctly
  (mkTest "devdependencies" ''
    for testScript in "pretest" "test" "posttest"; do
      test -f ${test-devdependencies}/build/''${testScript}
    done
  '')

  # Reported as "Infinite recursion"
  #
  # I didn't get that error while using the same code
  # Instead I got an issue accessing a peer-dependency which is not
  # in the shrinkwrap
  # This test passes using nix 2.0.4
  #
  # See github issue https://github.com/adisbladis/pnpm2nix/issues/1
  (mkTest "issue-1" ''
    echo ${issue-1}
  '')

])

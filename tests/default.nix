with (import ((import <nixpkgs> {}).fetchFromGitHub {
  repo = "nixpkgs";
  owner = "NixOS";
  sha256 = "sha256-IiJ0WWW6OcCrVFl1ijE+gTaP0ChFfV6dNkJR05yStmw=";
  rev = "eb751d65225ec53de9cf3d88acbf08d275882389";
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
  test-falsy-script = importTest ./test-falsy-script;
  test-filedeps = importTest ./file-dependencies;
  test-circular = importTest ./test-circular;
  test-scoped = importTest ./test-scoped;
  test-recursive-link = importTest ./recursive-link/packages/a;

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
    echo ${(python3.withPackages (ps: [ ps.flake8 ]))}/bin/flake8 ${pnpm2nix}/
  '')

  # Check if nested directory structures work properly
  (mkTest "nested-dirs" ''
    test -e ${lib.getLib nested-dirs}/node_modules/@types/node || (echo "Nested directory structure does not exist"; exit 1)
  '')

  # Check if peer dependencies are resolved
  (mkTest "peerdependencies" ''
    winstonPeer=$(readlink -f ${lib.getLib test-peerdependencies}/node_modules/winston-logstash/../winston)
    winstonRoot=$(readlink -f ${lib.getLib test-peerdependencies}/node_modules/winston)

    test "''${winstonPeer}" = "''${winstonRoot}" || (echo "Different versions in root and peer dependency resolution"; exit 1)
  '')

  # Test a "weird" package with -beta in version number spec
  (let
    web3Drv = lib.elemAt (lib.filter (x: x.name == "web3-1.0.0-beta.55") web3.buildInputs) 0;
  in mkTest "test-beta-names" ''
    test "${web3Drv.name}" = "web3-1.0.0-beta.55" || (echo "web3 name mismatch"; exit 1)
    test "${web3Drv.version}" = "1.0.0-beta.55" || (echo "web3 version mismatch"; exit 1)
  '')

  # Check if checkPhase is being run correctly
  (mkTest "devdependencies" ''
    for testScript in "pretest" "test" "posttest"; do
      test -f ${lib.getLib test-devdependencies}/node_modules/test-devdependencies/build/''${testScript}
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

  # Ensure package with falsy script (async-lock) builds
  (mkTest "test-falsy-scripts" ''
    echo ${test-falsy-script}
  '')

  # Test module local (file dependencies)
  (mkTest "test-filedeps" ''
    ${test-filedeps}/bin/test-module
  '')

  # Test circular dependencies are broken up and still works
  (mkTest "test-circular" ''
    HOME=$(mktemp -d) ${test-circular}/bin/test-circular
  '')

  # Test scoped package
  (mkTest "test-scoped" ''
    ${test-scoped}/bin/test-scoped
  '')

  # # Test pnpm workspace recursive linked packages
  # (mkTest "test-recursive-link" ''
  #   ${test-recursive-link}/bin/test-recursive-link
  # '')

])

{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, node-gyp ? nodePackages.node-gyp
}:


let
  inherit (pkgs) stdenv lib fetchurl;

  hasScript = scriptName: "test \"$(${pkgs.jq}/bin/jq -e -r '.scripts | .${scriptName} | length' < package.json)\" -gt 0";

  linkBinOutputsScript = ./link-bin-outputs.py;

in {

  mkPnpmDerivation = {
    attrs ? {},
    devDependencies ? [],
    deps ? [],
    linkDevDependencies,
  }: stdenv.mkDerivation (attrs //  {

    outputs = attrs.outputs or [ "out" "lib" ];

    # Only bin outputs specified in package.json should be patched
    # Trying to reduce some closure size
    dontPatchShebangs = true;

    nativeBuildInputs = with pkgs; [ pkgconfig ];

    buildInputs = [ nodejs nodejs.passthru.python node-gyp ]
      ++ lib.optionals (lib.hasAttr "buildInputs" attrs) attrs.buildInputs
      ++ lib.optionals linkDevDependencies devDependencies
      ++ deps;

    checkInputs = devDependencies;

    passthru = {
      inherit nodejs;
    };

    checkPhase = let
      runTestScript = scriptName: ''
        if ${hasScript scriptName}; then
          PATH="${lib.makeBinPath devDependencies}:$PATH" npm run-script ${scriptName}
        fi
      '';
    in attrs.checkPhase or ''
      runHook preCheck
      ${runTestScript "pretest"}
      ${runTestScript "test"}
      ${runTestScript "posttest"}
      runHook postCheck
    '';

    configurePhase = let
      linkDeps = deps ++ lib.optionals linkDevDependencies devDependencies;
    in attrs.configurePhase or ''
      runHook preConfigure

      # Because of the way the bin directive works, specifying both a bin path and setting directories.bin is an error
      if test `${pkgs.jq}/bin/jq '(.directories | has("bin")) and has("bin")' < package.json` = true; then
        echo "package.json had both bin and directories.bin (see https://docs.npmjs.com/files/package.json#directoriesbin)"
      fi

      # node-gyp writes to $HOME
      export HOME="$TEMPDIR"

      # Prevent gyp from going online (no matter if invoked by us or by package.json)
      export npm_config_nodedir="${nodejs}"

      # Link dependencies into node_modules
      mkdir -p node_modules
      ${lib.concatStringsSep "\n" (map (dep: "mkdir -p $(dirname node_modules/${dep.pname}) && ln -s ${lib.getLib dep} node_modules/${dep.pname}") linkDeps)}

      if ${hasScript "preinstall"}; then
        npm run-script preinstall
      fi

      runHook postConfigure
    '';

    buildPhase = attrs.buildPhase or ''
      runHook preBuild

      # If there is a binding.gyp file and no "install" or "preinstall" script in package.json "install" defaults to "node-gyp rebuild"
      if ${hasScript "install"}; then
        npm run-script install
      elif ${hasScript "preinstall"}; then
        true
      elif [ -f ./binding.gyp ]; then
        ${nodePackages.node-gyp}/bin/node-gyp rebuild
      fi

      if ${hasScript "postinstall"}; then
        npm run-script postinstall
      fi

      runHook postBuild
    '';

    installPhase = let
      linkBinOutputs = "${nodejs.passthru.python}/bin/python ${linkBinOutputsScript}";
    in attrs.installPhase or ''
      runHook preInstall

      mkdir -p "$out/bin" "$lib"
      cp -a * $lib/

      # Create bin outputs
      ${linkBinOutputs} "$out/bin/" "$lib" ./package.json | while read bin_in; do
        patchShebangs "$bin_in"
      done

      runHook postInstall
      '';
  });

}

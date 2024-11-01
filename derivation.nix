{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs
, nodePackages ? pkgs.nodePackages
, node-gyp ? nodePackages.node-gyp
}:


let
  inherit (pkgs) stdenv lib fetchurl;

  hasScript = scriptName: "test \"$(${pkgs.jq}/bin/jq -e -r '.scripts | .${scriptName} | length' < package.json)\" -gt 0";

  linkBinOutputsScript = ./link-bin-outputs.py;

in {

  mkPnpmDerivation = lib.makeOverridable ({
    attrs ? {},
    devDependencies ? [],
    deps ? [],
    linkDevDependencies,
    passthru ? {},
  }: stdenv.mkDerivation (attrs //  {

    outputs = attrs.outputs or [ "out" "lib" ];

    # Only bin outputs specified in package.json should be patched
    # Trying to reduce some closure size
    dontPatchShebangs = true;

    nativeBuildInputs = with pkgs; [ pkgconfig ];

    propagatedBuildInputs = [];

    buildInputs = [ nodejs nodejs.passthru.python node-gyp ]
      ++ lib.optionals (lib.hasAttr "buildInputs" attrs) attrs.buildInputs
      ++ lib.optionals linkDevDependencies devDependencies
      ++ deps;

    checkInputs = devDependencies;

    passthru = passthru // {
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

      for constituent in ''${constituents}; do
        cd "''${constituent}"
        ${runTestScript "pretest"}
        ${runTestScript "test"}
        ${runTestScript "posttest"}
        cd "''${build_dir}"
      done

      runHook postCheck
    '';

    sourceRoot = ".";
    postUnpack = ''
      mkdir -p node_modules
      cp -R pnpm2nix-source-*/* node_modules/
      rm -r pnpm2nix-source-*
    '';

    configurePhase = let
      linkDeps = deps ++ lib.optionals linkDevDependencies devDependencies;
      linkDep = dep: ''
        ls -d ${lib.getLib dep}/node_modules/* ${lib.getLib dep}/node_modules/@*/* | grep -Pv '(@[^/]+)$' | while read module; do
          if test ! -L "$module"; then
            # Check for nested directories (npm calls this scopes)
            if test "$(echo "$module" | grep -o '@')" = '@'; then
              scope=$(echo "${dep.pname}" | cut -d/ -f 1)
              outdir=node_modules/$scope
              mkdir -p "$outdir"
              ln -sf "$module" "$outdir"
            else
              ln -sf "$module" node_modules/ || :
            fi
          fi
        done
      '';
    in attrs.configurePhase or ''
      runHook preConfigure

      export constituents=$(ls -d node_modules/* node_modules/@*/* | grep -Pv '(@[^/]+)$')
      export build_dir=$(pwd)

      # Prevent gyp from going online (no matter if invoked by us or by package.json)
      export npm_config_nodedir="${nodejs}"

      # node-gyp writes to $HOME
      export HOME="$TEMPDIR"

      # Link dependencies into node_modules

      ${lib.concatStringsSep "\n" (map linkDep linkDeps)}

      for constituent in ''${constituents}; do
        cd "''${constituent}"
        if ${hasScript "preinstall"}; then
          npm run-script preinstall
        fi
        cd "''${build_dir}"
      done

      runHook postConfigure
    '';

    buildPhase = attrs.buildPhase or ''
      runHook preBuild

      for constituent in ''${constituents}; do
        cd "''${constituent}"
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
        cd "''${build_dir}"
      done

      runHook postBuild
    '';

    installPhase = let
      linkBinOutputs = "${nodejs.passthru.python}/bin/python ${linkBinOutputsScript}";
    in attrs.installPhase or ''
      runHook preInstall

      mkdir -p "$out/bin" "$lib"
      mv node_modules $lib/

      # Create bin outputs
      for constituent in ''${constituents}; do
        ${linkBinOutputs} "$out/bin/" "$lib/$constituent" | while read bin_in; do
          patchShebangs "$bin_in"
        done
      done

      runHook postInstall
      '';
  }));

}

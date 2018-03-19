{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, node-gyp ? nodePackages.node-gyp
}:

let
  inherit (pkgs) stdenv lib fetchurl;

  importYAML = name: shrinkwrapYML: (lib.importJSON ((pkgs.runCommandNoCC name {} ''
    mkdir -p $out
    ${pkgs.yaml2json}/bin/yaml2json < ${shrinkwrapYML} | ${pkgs.jq}/bin/jq -a '.' > $out/shrinkwrap.json
  '').outPath + "/shrinkwrap.json"));

  hasScript = scriptName: "test `${pkgs.jq}/bin/jq '.scripts | has(\"${scriptName}\")' < package.json` = true";

  linkBinOutputsScript = ./link-bin-outputs.py;

  mkPnpmDerivation = {
    attrs ? {},
    checkInputs ? [],
    deps ? []
  }: stdenv.mkDerivation (attrs //  {

    outputs = [ "out" "lib" ];

    # Only bin outputs specified in package.json should be patched
    # Trying to reduce some closure size
    dontPatchShebangs = true;

    buildInputs = [ nodejs nodejs.passthru.python node-gyp ]
      ++ (with pkgs; [ pkgconfig ])
      ++ lib.optionals (lib.hasAttr "buildInputs" attrs) attrs.buildInputs
      ++ deps;

    inherit checkInputs;

   checkPhase = ''
     runHook preCheck

     for testScript in "pretest" "test" "posttest"; do
        PATH="${lib.makeBinPath checkInputs}:$PATH" eval $(${pkgs.jq}/bin/jq -r ".scripts.''${testScript} // empty" < package.json)
      done

      runHook postCheck
    '';

    configurePhase = ''
      runHook preConfigure

      # Because of the way the bin directive works, specifying both a bin path and setting directories.bin is an error
      if test `${pkgs.jq}/bin/jq '(.directories | has("bin")) and has("bin")' < package.json` = true; then
        echo "package.json had both bin and directories.bin (see https://docs.npmjs.com/files/package.json#directoriesbin)"
      fi

      # node-gyp writes to $HOME
      export HOME="$TEMPDIR"

      if [[ -d node_modules || -L node_modules ]]; then
        echo "./node_modules is present. Removing."
        rm -rf node_modules
      fi

      # Prevent gyp from going online (no matter if invoked by us or by package.json)
      export npm_config_nodedir="${nodejs}"

      # Link dependencies into node_modules
      mkdir node_modules
      ${lib.concatStringsSep "\n" (map (dep: "mkdir -p $(dirname node_modules/${dep.pname}) && ln -s ${lib.getLib dep} node_modules/${dep.pname}") deps)}

      if ${hasScript "preinstall"}; then
        npm run-script preinstall
      fi

      runHook postConfigure
    '';

    buildPhase = ''
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

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$lib"
      cp -a * $lib/

      # Create bin outputs
      ${nodejs.passthru.python}/bin/python ${linkBinOutputsScript} "$out/bin/" "$lib" ./package.json | while read bin_in; do
        patchShebangs "$bin_in"
      done

      runHook postInstall
      '';
  });


  # TODO: Reimplement semver parsing in nix
  satisfiesSemver = version: versionSpec: (lib.importJSON ((pkgs.runCommandNoCC "semver" {} ''
    env NODE_PATH=${nodePackages.semver}/lib/node_modules ${nodejs}/bin/node -e 'console.log(require("semver").satisfies("${version}", "${versionSpec}"))' > $out
  '').outPath));
  versionSpecMatches = (drv: versionSpec: satisfiesSemver drv.version versionSpec);

  resolvePeerDependency = with builtins; (pname: versionSpec: modules:
    lib.elemAt (builtins.sort (a: b: lib.versionOlder b.version a.version) (filter (drv: versionSpecMatches drv versionSpec)
      (filter (drv: drv.pname == pname)
        (lib.mapAttrsFlatten (k: v: v) modules)))) 0);

  overrideDerivation = (overrides: drv:
    if (lib.hasAttr drv.pname overrides) then
      (overrides."${drv.pname}" drv)
        else drv);

  resolveDependencies = pkgInfo: modules: (lib.mapAttrsFlatten
    (k: v: if (lib.hasAttr v modules) then modules."${v}" else modules."/${k}/${v}")
      ((if (lib.hasAttr "dependencies" pkgInfo) then pkgInfo.dependencies else {}) // (if (lib.hasAttr "optionalDependencies" pkgInfo) then pkgInfo.optionalDependencies else {})));

  # TODO: Merge this function with resolveDependencies
  resolveDevDependencies = pkgInfo: modules: (lib.mapAttrsFlatten
    (k: v: if (lib.hasAttr v modules) then modules."${v}" else modules."/${k}/${v}")
      ((if (lib.hasAttr "devDependencies" pkgInfo) then pkgInfo.devDependencies else {})));

in {

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    overrides ? {},
    allowImpure ? false,
    ...
  } @args:
  let
    specialAttrs = [ "packageJSON" "shrinkwrapYML" "overrides" "allowImpure" ];

    package = lib.importJSON packageJSON;
    pname = package.name;
    version = package.version;
    name = pname + "-" + version;

    shrinkwrap = importYAML "${pname}-shrinkwrap-${version}" shrinkwrapYML;

    modules = with lib;
      (listToAttrs (map (drv: nameValuePair drv.pkgName (overrideDerivation overrides drv))
        (map (name: (mkPnpmModule name shrinkwrap.packages."${name}"))
          (lib.attrNames shrinkwrap.packages))));

    mkPnpmModule = pkgName: pkgInfo: let
      integrity = lib.splitString "-" pkgInfo.resolution.integrity;
      shaType = lib.elemAt integrity 0;
      shaSum = lib.elemAt integrity 1;

      rawPname = lib.elemAt (builtins.match "(/|)(.+?)/[0-9].*" pkgName) 1;
      pname = if (lib.hasAttr "name" pkgInfo)
        then pkgInfo.name else rawPname;
      version = if (lib.hasAttr "version" pkgInfo)
        then pkgInfo.version else (lib.elemAt (builtins.match ".*?/([0-9][A-Za-z\.0-9\.\-]+).*" pkgName) 0);
      name = (lib.replaceStrings [ "@" "/" ] [ "" "-" ] pname) + "-" + version;

      tarball = (lib.lists.last (lib.splitString "/" rawPname)) + "-" + version + ".tgz";
      src = (if (lib.hasAttr "integrity" pkgInfo.resolution) then
        pkgs.fetchurl {
          # Note: Tarballs do not have checksums yet
          # https://github.com/pnpm/pnpm/issues/1035
          url = if (lib.hasAttr "tarball" pkgInfo.resolution)
            then pkgInfo.resolution.tarball
            else "${shrinkwrap.registry}${pname}/-/${tarball}";
          "${shaType}" = shaSum;

          } else if allowImpure then fetchTarball {
            # Once pnpm has integrity sums for tarballs impure builds should be dropped
            url = pkgInfo.resolution.tarball;
          } else throw "No download method found");

      peerDependencies = (if (lib.hasAttr "peerDependencies" pkgInfo)
        then (lib.mapAttrsFlatten (k: v:
          (resolvePeerDependency k v modules)) pkgInfo.peerDependencies)
        else []);

      deps = lib.unique ((resolveDependencies pkgInfo modules) ++ peerDependencies);

    in mkPnpmDerivation {
      inherit deps;
      attrs = { inherit name src pname version pkgName; };
    };

  in
    assert shrinkwrap.shrinkwrapVersion == 3;
  (mkPnpmDerivation {
    deps = (resolveDependencies shrinkwrap modules);
    checkInputs = (resolveDevDependencies shrinkwrap modules);
    # Filter "special" attrs we know how to interpret, merge rest to drv attrset
    attrs = ((lib.filterAttrs (k: v: !(lib.lists.elem k specialAttrs)) args) // {
      inherit name pname version;
    });
  });


}

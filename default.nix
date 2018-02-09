{ pkgs ? import <nixpkgs> {}
, python2 ? pkgs.python2
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, pnpm ? pkgs.nodePackages_8_x.pnpm
}:

let
  inherit (pkgs) stdenv lib fetchurl;

  registryURL = "https://registry.npmjs.org/";

  importYAML = name: shrinkwrapYML: (lib.importJSON ((pkgs.runCommandNoCC name {} ''
    mkdir -p $out
    ${pkgs.callPackage ./yml2json { }}/bin/yaml2json < ${shrinkwrapYML} | ${pkgs.jq}/bin/jq -a '.' > $out/shrinkwrap.json
  '').outPath + "/shrinkwrap.json"));

  hasScript = scriptName: "test `${pkgs.jq}/bin/jq '.scripts | has(\"${scriptName}\")' < package.json` = true";

  nodeSources = pkgs.runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';

  mkPnpmDerivation = deps: attrs: stdenv.mkDerivation (attrs //  {

    buildInputs = [ nodejs python2 ]
      ++ lib.optionals (lib.hasAttr "buildInputs" attrs) attrs.buildInputs;

    configurePhase = ''
      runHook preConfigure

      # node-gyp writes to $HOME
      export HOME="$TEMPDIR"

      # Prevent gyp from going online (no matter if invoked by us or by package.json)
      export npm_config_nodedir=${nodeSources}

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      if [[ -d node_modules || -L node_modules ]]; then
        echo "./node_modules is present. Removing."
        rm -rf node_modules
      fi

      # Link dependencies into node_modules
      mkdir node_modules
      ${lib.concatStringsSep "\n" (map (dep: "ln -s ${dep} node_modules/${dep.pname}") deps)}

      if ${hasScript "preinstall"}; then
        npm run-script preinstall
      fi

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

      mkdir -p $out
      cp -a * $out/

      runHook postInstall
      '';
  });


in {

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    extraBuildInputs ? {},
  }:
    let
      package = lib.importJSON packageJSON;
      pname = package.name;
      version = package.version;
      name = pname + "-" + version;

      shrinkwrap = importYAML "${pname}-shrinkwrap-${version}" shrinkwrapYML;

      modules = with lib;
        (listToAttrs (map (drv: nameValuePair drv.pkgName drv)
          (map (name: (mkPnpmModule name shrinkwrap.packages."${name}"))
            (lib.attrNames shrinkwrap.packages))));

      mkPnpmModule = pkgName: pkgInfo: let
        integrity = lib.splitString "-" pkgInfo.resolution.integrity;
        shaType = lib.elemAt integrity 0;
        shaSum = lib.elemAt integrity 1;

        nameComponents = lib.splitString "/" pkgName;
        pname = if (lib.hasAttr "name" pkgInfo)
          then pkgInfo.name else lib.elemAt nameComponents 1;
        version = if (lib.hasAttr "version" pkgInfo)
          then pkgInfo.version else lib.elemAt nameComponents 2;
        name = pname + "-" + version;

        innerDeps = if (lib.hasAttr "dependencies" pkgInfo) then
          (map (dep: modules."${dep}")
            (lib.mapAttrsFlatten (k: v: "/${k}/${v}") pkgInfo.dependencies))
          else [];

        src = pkgs.fetchurl {
          # Note: Tarballs do not have checksums yet
          # https://github.com/pnpm/pnpm/issues/1035
          url = if (lib.hasAttr "tarball" pkgInfo.resolution)
            then pkgInfo.resolution.tarball
            else "${shrinkwrap.registry}${pname}/-/${name}.tgz";
          "${shaType}" = shaSum;
        };

        buildInputs = if (lib.hasAttr pname extraBuildInputs) then
          (lib.getAttr pname extraBuildInputs) else [];

      in mkPnpmDerivation innerDeps {
        inherit name src pname version buildInputs;
        inherit pkgName;  # TODO: Remove this hack
      };

      deps = (map (dep: modules."${dep}")
        (lib.mapAttrsFlatten (k: v: "/${k}/${v}") shrinkwrap.dependencies));

    in
    assert shrinkwrap.shrinkwrapVersion == 3;
    mkPnpmDerivation deps {
      inherit name pname version src;
    };

}

{ pkgs ? import <nixpkgs> {}
, python2 ? pkgs.python2
, nodejs ? pkgs.nodejs
, nodePackages_8_x ? pkgs.nodePackages_8_x
, pnpm ? pkgs.nodePackages_8_x.pnpm
}:

let
  inherit (pkgs) stdenv lib fetchurl linkFarm;

  registryURL = "https://registry.npmjs.org/";

  jsonFile = name: shrinkwrapYML: (lib.importJSON ((pkgs.runCommandNoCC name {} ''
    mkdir -p $out
    ${pkgs.callPackage ./yml2json { }}/bin/yaml2json < ${shrinkwrapYML} > $out/shrinkwrap.json
  '').outPath + "/shrinkwrap.json"));


in {

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    extraBuildInputs ? [],
  }:
    let
      package = lib.importJSON packageJSON;
      pname = package.name;
      version = package.version;
      name = pname + "-" + version;

      shrinkwrap = jsonFile "shrinkwrap" shrinkwrapYML;

      modules = with lib;
        (listToAttrs (map (drv: nameValuePair drv.pkgName drv)
          (map (name: (mkPnpmModule name shrinkwrap.packages."${name}"))
            (lib.attrNames shrinkwrap.packages))));

      mkPnpmModule = pkgName: pkgInfo: let
        integrity = lib.splitString "-" pkgInfo.resolution.integrity;
        shaType = lib.elemAt integrity 0;
        shaSum = lib.elemAt integrity 1;

        nameComponents = lib.splitString "/" pkgName;
        pname = lib.elemAt nameComponents 1;
        version = lib.elemAt nameComponents 2;
        name = pname + "-" + version;

        innerDeps = if (lib.hasAttr "dependencies" pkgInfo) then
          (map (dep: modules."${dep}")
            (lib.mapAttrsFlatten (k: v: "/${k}/${v}") pkgInfo.dependencies))
          else [];

        # TODO: Support other registrys
        url = "https://registry.npmjs.org/${pname}/-/${name}.tgz";

      in stdenv.mkDerivation {
        inherit name pname version;
        inherit pkgName;

        src = pkgs.fetchurl {
          inherit url;
          "${shaType}" = shaSum;
        };

        buildInputs = [ nodejs python2 ];

        configurePhase = ''
          runHook preConfigure

          if test -f ./binding.gyp; then
            ${nodePackages_8_x.node-gyp}/bin/node-gyp configure
          fi

          runHook postConfigure
        '';

        buildPhase = ''
          runHook preBuild

          # Link dependencies into node_modules
          mkdir node_modules
          ${lib.concatStringsSep "\n" (map (dep: "ln -s ${dep} node_modules/${dep.pname}") innerDeps)}

          npm build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out
          cp -a * $out/

          runHook postInstall
        '';

      };

      deps = (map (dep: modules."${dep}")
        (lib.mapAttrsFlatten (k: v: "/${k}/${v}") shrinkwrap.dependencies));

    in
    assert shrinkwrap.shrinkwrapVersion == 3;
    stdenv.mkDerivation {
      inherit name pname version src;

      buildInputs = [ nodejs python2 ];

      configurePhase = ''
        runHook preConfigure

        if [[ -d node_modules || -L node_modules ]]; then
          echo "./node_modules is present. Removing."
          rm -rf node_modules
        fi

        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild

        # Link dependencies into node_modules
        mkdir node_modules
        ${lib.concatStringsSep "\n" (map (dep: "ln -s ${dep} node_modules/${dep.pname}") deps)}

        npm build

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -a * $out/
        runHook postInstall
      '';

    };

}

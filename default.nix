{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, node-gyp ? nodePackages.node-gyp
}:

# Scope mkPnpmDerivation
with (import ./derivation.nix {
     inherit pkgs nodejs nodePackages node-gyp;
});
with pkgs;

let

  rewriteShrinkWrap = import ./shrinkwrap.nix {
    inherit pkgs nodejs nodePackages;
  };

  importYAML = name: yamlFile: (lib.importJSON ((pkgs.runCommandNoCC name {} ''
    mkdir -p $out
    ${pkgs.yaml2json}/bin/yaml2json < ${yamlFile} | ${pkgs.jq}/bin/jq -a '.' > $out/shrinkwrap.json
  '').outPath + "/shrinkwrap.json"));

  overrideDrv = (overrides: drv:
    if (lib.hasAttr drv.pname overrides) then
      (overrides."${drv.pname}" drv)
        else drv);

in {

  mkPnpmEnv = drv: let
    envDrv = (drv.override {linkDevDependencies = true;}).overrideAttrs(oldAttrs: {
      src = lib.cleanSourceWith {
        filter = (name: type: baseNameOf (toString name) == "package.json");
        src = oldAttrs.src; };
      outputs = [ "out" ];
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out
        mv node_modules $out
      '';
    });
  in makeSetupHook { deps = envDrv.buildInputs; } (writeScript "pnpm-env-hook.sh" ''
    export NODE_PATH=${lib.getLib envDrv}/node_modules
  '');

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    overrides ? {},
    allowImpure ? false,
    linkDevDependencies ? false,
    ...
  } @args:
  let
    specialAttrs = [ "packageJSON" "shrinkwrapYML" "overrides" "allowImpure" ];

    package = lib.importJSON packageJSON;
    pname = package.name;
    version = package.version;
    name = pname + "-" + version;

    shrinkwrap = let
      shrink = importYAML "${pname}-shrinkwrap-${version}" shrinkwrapYML;
    in rewriteShrinkWrap shrink;

    # Convert pnpm package entries to nix derivations
    packages = lib.mapAttrs (n: v: (let
      drv = mkPnpmModule n v;
      overriden = overrideDrv overrides drv;
    in overriden)) shrinkwrap.packages;

    mkPnpmModule = pkgName: pkgInfo: let
      integrity = lib.splitString "-" pkgInfo.resolution.integrity;
      shaType = lib.elemAt integrity 0;
      shaSum = lib.elemAt integrity 1;

      # These attrs have already been created in pre-processing
      inherit (pkgInfo) pname version name;

      tarball = (lib.lists.last (lib.splitString "/" pname)) + "-" + version + ".tgz";
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

      deps = builtins.map (attrName: packages."${attrName}") pkgInfo.dependencies;

    in
      mkPnpmDerivation {
        inherit deps;
        attrs = { inherit name src pname version pkgName; };
        linkDevDependencies = false;
      };

  in
    assert shrinkwrap.shrinkwrapVersion == 3;
  (mkPnpmDerivation {
    deps = (builtins.map
      (attrName: packages."${attrName}")
      (shrinkwrap.dependencies ++ shrinkwrap.optionalDependencies));

    devDependencies = builtins.map
      (attrName: packages."${attrName}") shrinkwrap.devDependencies;

    inherit linkDevDependencies;

    # Filter "special" attrs we know how to interpret, merge rest to drv attrset
    attrs = ((lib.filterAttrs (k: v: !(lib.lists.elem k specialAttrs)) args) // {
      inherit name pname version;
    });
  });

}

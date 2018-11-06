{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, nodePackages ? pkgs.nodePackages_8_x
, node-gyp ? nodePackages.node-gyp
} @modArgs:

# Scope mkPnpmDerivation
with (import ./derivation.nix {
     inherit pkgs nodejs nodePackages node-gyp;
});
with pkgs;

let

  # Replace disallowed characters from package name
  # @acme/package -> acme-package
  safePkgName = name: builtins.replaceStrings ["@" "/"] ["" "-"] name;

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

  defaultPnpmOverrides = import ./overrides.nix {
    inherit pkgs nodejs nodePackages;
  };

in {

  inherit defaultPnpmOverrides;

  # Create a nix-shell friendly development environment
  mkPnpmEnv = drv: let
    pkgJSON = writeText "${drv.name}-package-json" (builtins.toJSON drv.passthru.packageJSON);
    envDrv = (drv.override {linkDevDependencies = true;}).overrideAttrs(oldAttrs: {
      propagatedBuildInputs = [
        # Avoid getting npm and its deps in environment
        (drv.passthru.nodejs.override { enableNpm = false; })
        # Users probably want pnpm
        nodePackages.pnpm
      ];
      srcs = [];
      src = pkgs.runCommandNoCC "pnpm2nix-dummy-env-src" {} ''
        mkdir $out
      '';
      # Remove original nodejs from inputs, it's now propagated and stripped from npm
      buildInputs = builtins.filter (x: x != drv.passthru.nodejs) oldAttrs.buildInputs;
      outputs = [ "out" ];
      buildPhase = "true";
      postUnpack = ''
        mkdir -p node_modules/${oldAttrs.pname}
        ln -s ${pkgJSON} node_modules/${oldAttrs.pname}/package.json
      '';
      installPhase = ''
        mkdir -p $out
        mv node_modules $out
      '';
    });
  in makeSetupHook {
    deps = envDrv.buildInputs ++ envDrv.propagatedBuildInputs;
  } (writeScript "pnpm-env-hook.sh" ''
    export NODE_PATH=${lib.getLib envDrv}/node_modules
  '');

  mkPnpmPackage = {
    src,
    packageJSON ? src + "/package.json",
    shrinkwrapYML ? src + "/shrinkwrap.yaml",
    overrides ? defaultPnpmOverrides,
    allowImpure ? false,
    linkDevDependencies ? false,
    ...
  } @args:
  let
    specialAttrs = [ "src" "packageJSON" "shrinkwrapYML" "overrides" "allowImpure" ];

    package = lib.importJSON packageJSON;
    pname = safePkgName package.name;
    version = package.version;
    name = pname + "-" + version;

    shrinkwrap = let
      shrink = importYAML "${pname}-shrinkwrap-${version}" shrinkwrapYML;
    in rewriteShrinkWrap shrink;

    # Convert pnpm package entries to nix derivations
    packages = let

      linkPath = src: link: src + ("/" + (lib.removePrefix "link:" link));

      # Normal (registry/git) packages
      nonLocalPackages = lib.mapAttrs (n: v: (let
        drv = mkPnpmModule v;
        overriden = overrideDrv overrides drv;
      in overriden)) shrinkwrap.packages;

      # Local (link:) packages
      localPackages = let
        attrNames = builtins.filter (a: lib.hasPrefix "link:" a) shrinkwrap.dependencies;

        # Try to resolve relative path and import package.json to read package name
        resolvePkgName = (link: (lib.importJSON ((linkPath src link) + "/package.json")).name);
        resolve = (link: lib.nameValuePair link (resolvePkgName link));
        resolvedSpecifiers = lib.listToAttrs (map (resolve) attrNames);

      in lib.mapAttrs (n: v: let
        # Note: src can only be local path for link: dependencies
        pkgPath = linkPath src n;
        pkg = ((import ./default.nix modArgs).mkPnpmPackage {
          inherit allowImpure;
          src = pkgPath;
          packageJSON = pkgPath + "/package.json";
          shrinkwrapYML = pkgPath + "/shrinkwrap.yaml";
        }).overrideAttrs(oldAttrs: {
          src = wrapRawSrc pkgPath oldAttrs.pname;
        });
      in pkg) resolvedSpecifiers;
    in nonLocalPackages // localPackages;

    # Wrap sources in a directory named the same as the node_modules/ path
    wrapRawSrc = src: pname: (stdenv.mkDerivation (let
      name = safePkgName pname;
    in {
      name = "pnpm2nix-source-${name}";
      inherit src;
      dontBuild = true;
      configurePhase = ":";
      fixupPhase = ":";
      installPhase = ''
        mkdir -p $out/${pname}
        cp -a * $out/${pname}/
      '';
    }));
    wrapSrc = pkgInfo: let
      integrity = lib.splitString "-" pkgInfo.resolution.integrity;
      shaType = lib.elemAt integrity 0;
      shaSum = lib.elemAt integrity 1;
      tarball = (lib.lists.last (lib.splitString "/" pkgInfo.pname)) + "-" + pkgInfo.version + ".tgz";
      src = (if (lib.hasAttr "integrity" pkgInfo.resolution) then
        (pkgs.fetchurl {
          url = if (lib.hasAttr "tarball" pkgInfo.resolution)
            then pkgInfo.resolution.tarball
            else "${shrinkwrap.registry}${pkgInfo.pname}/-/${tarball}";
            "${shaType}" = shaSum;
        }) else if allowImpure then fetchTarball {
          # Note: Resolved tarballs(github revs for example)
          # does not yet have checksums
          # https://github.com/pnpm/pnpm/issues/1035
          url = pkgInfo.resolution.tarball;
        } else throw "No download method found for package ${pkgInfo.name}, consider adding `allowImpure = true;`");
    in wrapRawSrc src pkgInfo.pname;

    mkPnpmModule = pkgInfo: let
      hasCycle = (builtins.length pkgInfo.constituents) > 1;

      # These attrs have already been created in pre-processing
      # Cyclic dependencies has deterministic ordering so they will end up with the exact same attributes
      name = lib.concatStringsSep "-" (builtins.map (attr: shrinkwrap.packages."${attr}".name) pkgInfo.constituents);
      version = if !hasCycle then pkgInfo.version else "cyclic";
      pname = lib.concatStringsSep "-" (builtins.map (attr: shrinkwrap.packages."${attr}".pname) pkgInfo.constituents);

      srcs = (builtins.map (attr: wrapSrc shrinkwrap.packages."${attr}") pkgInfo.constituents);

      deps = builtins.map (attrName: packages."${attrName}")
        # Get all dependencies from cycle
        (lib.unique (lib.flatten (builtins.map
          (attr: shrinkwrap.packages."${attr}".dependencies) pkgInfo.constituents)));

    in
      mkPnpmDerivation {
        inherit deps;
        attrs = { inherit name srcs pname version; };
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

    passthru = {
      packageJSON = package;
    };

    # Filter "special" attrs we know how to interpret, merge rest to drv attrset
    attrs = ((lib.filterAttrs (k: v: !(lib.lists.elem k specialAttrs)) args) // {
      srcs = [ (wrapRawSrc src pname) ];
      inherit name pname version;
    });
  });

}

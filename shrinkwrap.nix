{ pkgs
, nodejs
, nodePackages
}:

with pkgs;

# Rewrite the shrinkwrap graph to be a DAG and pre-resolve all dependencies to
# absolute attribute names in the shrinkwrap packages attribute set.
#
# After rewriting you end up with a datastructure that looks like (JSON):
# {
#   "dependencies": [ "/yargs/8.0.2" ],
#   "devDependencies": [],
#   "optionalDependencies": [],
#   "packages": {
#     "/camelcase/4.1.0": {
#       "constituents": [ "/camelcase/4.1.0" ],
#       "dependencies": [],
#       "dev": false,
#       "engines": { "node": ">=4" },
#       "name": "camelcase-4.1.0",
#       "peerDependencies": [],
#       "pname": "camelcase",
#       "rawPname": "camelcase",
#       "resolution": { "integrity": "sha1-1UVjW+HjPFQmScaRc+Xeas+uNN0=" },
#       "version": "4.1.0"
#     },
#     "/yargs/8.0.2": {
#       "constituents": [ "/yargs/8.0.2" ],
#       "dependencies": [ "/camelcase/4.1.0" ],
#       "dev": false,
#       "name": "yargs-8.0.2",
#       "peerDependencies": [],
#       "pname": "yargs",
#       "rawPname": "yargs",
#       "resolution": { "integrity": "sha1-YpmpBVsc78lp/355wdkY3Osiw2A=" },
#       "version": "8.0.2"
#     }
#   },
#   "registry": "https://registry.npmjs.org/",
#   "shrinkwrapMinorVersion": 6,
#   "shrinkwrapVersion": 3,
#   "specifiers": {},
# }

let

  # Find index of elem in list
  indexOf = let
    _indexOf = elem: list: idx: let
      cur = lib.elemAt list idx;
    in
      if lib.lists.length list == 0 then null
      else if cur == elem then idx
      else (_indexOf elem list (idx+1));
  in (elem: list: _indexOf elem list 0);

  # TODO: Reimplement semver parsing in nix
  satisfiesSemver = version: versionSpec: (lib.importJSON ((pkgs.runCommandNoCC "semver" {} ''
    env NODE_PATH=${nodePackages.semver}/lib/node_modules ${nodejs}/bin/node -e 'console.log(require("semver").satisfies("${version}", "${versionSpec}"))' > $out
  '').outPath));
  versionSpecMatches = (version: versionSpec: satisfiesSemver version versionSpec);

  # Extract further required info from attrsets:
  # resolution

  # This function sets 4 attributes on each entry
  # from shrinkwrap.packages:
  #
  # packageSet: packages from shrinkwrap.yaml
  #
  # name: The nix derivation name
  # rawPname: npm package name
  # pname: The name portion of the package name (derivation name)
  # name: Nix derivation name attr
  # version: Nix derivation version attr
  injectNameVersionAttrs = packageSet: let

      getDrvVersionAttr = pkgAttr: (lib.elemAt
        (builtins.match ".*?/([0-9][A-Za-z\.0-9\.\-]+).*" pkgAttr) 0);

      addAttrs = (acc: pkgAttr: acc // (let
        pkg = acc."${pkgAttr}";
      in {
        "${pkgAttr}" = (pkg // rec {
          rawPname = lib.elemAt (builtins.match "(/|)(.+?)/[0-9].*" pkgAttr) 1;
          pname = if (lib.hasAttr "name" pkg)
            then pkg.name
            else rawPname;
          name = (lib.replaceStrings [ "@" "/" ] [ "" "-" ] pname) + "-" + version;
          version = if (lib.hasAttr "name" pkg)
            then pkg.version
            else (getDrvVersionAttr pkgAttr);
        });
      }));

    in lib.foldl addAttrs packageSet (lib.attrNames packageSet);

  # Resolve peer dependencies to shrinkwrap attribute names
  #
  # packageSet: packages from shrinkwrap.yaml
  resolvePackagePeerDependencies = packageSet: let

      # Resolve a single pname+versionSpec from graph
      resolve = pname: versionSpec: with builtins; let
         nameMatches = lib.filterAttrs (n: v: v.pname == pname) packageSet;
         matches = lib.filterAttrs (n: v:
           versionSpecMatches v.version versionSpec) nameMatches;
         matchPairs =  lib.mapAttrsToList (name: value:
           {inherit name; version = value.version;}) matches;
         sorted = builtins.sort (a: b:
           lib.versionOlder b.version a.version) matchPairs;
         hasMatch = lib.length sorted > 0;
         finalMatch = lib.elemAt sorted 0;
        in if hasMatch then finalMatch.name else null;

      rewriteAttrSet = (acc: pkgAttr: acc // (let
        pkg = acc."${pkgAttr}";
        attrSet = if (lib.hasAttr "peerDependencies" pkg)
          then pkg.peerDependencies
          else {};

        peerDependencies = lib.foldl (acc: pkgAttr: (let
            match = (resolve pkgAttr attrSet."${pkgAttr}");
            ret = if (match != null) then (acc ++ [ match ]) else acc;
          in ret)) [] (lib.attrNames attrSet);
      in {
        "${pkgAttr}" = (pkg // {
          inherit peerDependencies;
        });
      }));

    in lib.foldl rewriteAttrSet packageSet (lib.attrNames packageSet);

  # Find the attribute name for a shrinkwrap package
  findAttrName = attrSet: depName: depVersion: let
    slashed = "/${depName}/${depVersion}";
  in if (lib.hasAttr slashed attrSet) then slashed else depVersion;

  # Resolve dependencies to shrinkwrap attribute names
  #
  # packageSet: packages from shrinkwrap.yaml
  resolvePackageDependencies = packageSet: let

      rewriteAttrSet = (acc: pkgAttr: acc // (let
        pkg = acc."${pkgAttr}";
        attrSet = (if (lib.hasAttr "dependencies" pkg)
          then pkg.dependencies
          else {}) // (if (lib.hasAttr "optionalDependencies" pkg)
            then pkg.optionalDependencies
            else {});

        baseDependencies = lib.foldl (acc: depName: (let
            depVersion = attrSet."${depName}";
            ret = acc ++ [ (findAttrName packageSet depName depVersion) ];
          in ret)) [] (lib.attrNames attrSet);

        # Create a list of pnames so we can filter out any peerDependencies weirdness
        basePnames = builtins.map (attrName: packageSet."${attrName}".pname) baseDependencies;
        # Filter out pre-resolved (by pnpm) peer dependencies
        dependencies =
          builtins.filter (attrName: !(lib.elem packageSet."${attrName}".pname basePnames)) pkg.peerDependencies
          ++ baseDependencies;

      in {
        "${pkgAttr}" = (pkg // {
          dependencies = lib.unique dependencies;
        });
      }));

    in lib.foldl rewriteAttrSet packageSet (lib.attrNames packageSet);

  # Resolve top-level dependencies to shrinkwrap attribute names
  #
  # packageSet: packages from shrinkwrap.yaml
  resolveDependencies = shrinkwrap: let
      packageSet = shrinkwrap.packages;

      rewriteAttrs = attr: let
        attrSet = if (lib.hasAttr attr shrinkwrap)
          then shrinkwrap."${attr}"
          else {};
      in lib.mapAttrsToList (depName: depVersion:
        (findAttrName packageSet depName depVersion)) attrSet;

    in shrinkwrap // {
      dependencies = rewriteAttrs "dependencies";
      devDependencies = rewriteAttrs "devDependencies";
      optionalDependencies = rewriteAttrs "optionalDependencies";
    };

  # Something something
  breakCircular = dependencyAttributes: packageSet: let
    walkGraph = (pkgAttr: visitStack: acc: let
      # Scope the current entry for convenience
      entry = acc."${pkgAttr}";
      hasDeps = lib.length entry.dependencies > 0;
      deps = entry.dependencies;

      # Detect cycles by seeing if the exact shrinkwrap package
      # has already been visited
      hasCycle = lib.elem pkgAttr visitStack;

      # If there is a cycle we have to know where to start rewriting
      # the dependency graph
      cycleIndex = indexOf pkgAttr visitStack;

      # List of constituents in this cycle
      # This is a list of attribute names poped from the visit stack
      #
      # The list is sorted to provide the exact same ordering no matter
      # where the cycle was entered
      cycleConstituents = lib.lists.sort (a: b: a < b) (if hasCycle then
        (lib.lists.sublist cycleIndex (lib.lists.length visitStack) visitStack)
        else [ pkgAttr ]);

      # Modify the accumulator with constituents
      #
      # We also need to remove the cycled dependencies from the inputs
      # to stop furter recursion
      rewrittenSet = lib.foldl (acc: attrName: (acc // (let
        constituent = acc."${attrName}";
        constituentDeps = constituent.dependencies;
        dependencies = lib.filter (depAttr: !(lib.elem depAttr cycleConstituents)) constituentDeps;
      in {
        "${attrName}" = (constituent // {
          constituents = cycleConstituents;
          inherit dependencies;
        });
      }))) acc cycleConstituents;

      # Walk deeper in the graph if there are dependencies
      reducedNodes = let
        addedVisit = visitStack ++ [ pkgAttr ];
      in
      assert !hasCycle;
      lib.foldl (a: depAttr: walkGraph depAttr addedVisit a) rewrittenSet deps;

    in if hasDeps then reducedNodes else rewrittenSet);

  in lib.foldl (acc: attrName: acc //
    (walkGraph attrName [] acc)) packageSet dependencyAttributes;

  rewriteGraph = shrinkwrap: lib.foldl (acc: fn: fn acc) shrinkwrap [

    # Inject pname, version etc attributes
    (shrinkwrap: shrinkwrap // {
      packages = injectNameVersionAttrs shrinkwrap.packages;
    })

    # Resolve all peer dependencies to attribute names
    (shrinkwrap: shrinkwrap // {
      packages = resolvePackagePeerDependencies shrinkwrap.packages;
    })

    # Resolve all dependencies to attribute names
    (shrinkwrap: shrinkwrap // {
      packages = resolvePackageDependencies shrinkwrap.packages;
    })

    # Resolve all top-level dependencies (dependencies & devDependencies)
    (shrinkwrap: resolveDependencies shrinkwrap)

    # Lets play break the cycle!
    # npm allows for circular dependencies (insanity)
    #
    # We need to de-cycle the graph to not cause infinite recursions
    # We do this by aggregating a cycle into a single derivation per cycle
    #
    # In a single-package context circular can be achieved without causing
    # infinite recursion
    (shrinkwrap: shrinkwrap // (let
      # Avoid unnecessary processing by walking from root out to the leaf(s)
      #
      # TODO: Dont include devDependencies and optionalDependencies unconditionally
      # We could easily optimise this away by only walking if they are included
      dependencyAttributes = lib.unique (shrinkwrap.dependencies
        ++ shrinkwrap.devDependencies
        ++ shrinkwrap.optionalDependencies);
    in {
      packages = breakCircular dependencyAttributes shrinkwrap.packages;
    }))
  ];

in (shrinkwrapYAML: rewriteGraph shrinkwrapYAML)

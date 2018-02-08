with (import <nixpkgs> {});
with (import ../. { inherit pkgs; });

mkPnpmPackage {
  src = ./.;
  # These default to src/package.json & src/shrinkwrap.yaml
  packageJSON = ./package.json;
  shrinkwrapYML = ./shrinkwrap.yaml;
}

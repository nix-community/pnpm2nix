{ pkgs ? (import <nixpkgs> {})}:
with pkgs;
with (import ../../. { inherit pkgs; });

# Building this package requires an override (in default overrides)
mkPnpmPackage {
  src = ./.;
  packageJSON = ./package.json;
  shrinkwrapYML = ./shrinkwrap.yaml;
}

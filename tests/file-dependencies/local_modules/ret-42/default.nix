{ pkgs ? (import <nixpkgs> {})}:
with pkgs;
with (import ../../../../. { inherit pkgs; });
let
  package = mkPnpmPackage {

    src = lib.cleanSource ./.;
    packageJSON = ./package.json;
    shrinkwrapYML = ./shrinkwrap.yaml;
  };

in package

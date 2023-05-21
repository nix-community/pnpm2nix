{ pkgs ? (import <nixpkgs> {})}:
with pkgs;
with (import ../../. { inherit pkgs; });
let
  package = mkPnpmPackage {

    doCheck = true;

    preCheck = ''
      mkdir -p build
    '';

    postCheck = ''
      mkdir -p $out
      mv build $out/
    '';

    src = ./.;
    packageJSON = ./package.json;
    pnpmLock = ./pnpm-lock.yaml;
    linkDevDependencies = true;
  };

in package

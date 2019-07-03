{ pkgs ? (import <nixpkgs> {})}:
with pkgs;
with (import ../../. { inherit pkgs; });

mkPnpmPackage {
  src = ./.;
  allowImpure = true;
  packageJSON = ./package.json;
  pnpmLock = ./pnpm-lock.yaml;
}

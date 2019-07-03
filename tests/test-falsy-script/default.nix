{ pkgs ? (import <nixpkgs> {})}:
with pkgs;
with (import ../../. { inherit pkgs; });

mkPnpmPackage {
  src = ./.;
  packageJSON = ./package.json;
  pnpmLock = ./pnpm-lock.yaml;
}

{ stdenv, buildGoPackage, fetchFromGitHub }:

let
  rev = "ee8196e587313e98831c040c26262693d48c1a0c";

in buildGoPackage rec {
  name = "yaml2json-${version}";
  version = "unstable-${rev}";
  goPackagePath = "github.com/bronze1man/yaml2json";

  goDeps = ./deps.nix;

  src = fetchFromGitHub {
    inherit rev;
    owner = "bronze1man";
    repo = "yaml2json";
    sha256 = "16a2sqzbam5adbhfvilnpdabzwncs7kgpr0cn4gp09h2imzsprzw";
  };
}

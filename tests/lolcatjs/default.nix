with (import <nixpkgs> {});
with (import ../../. { inherit pkgs; });

let
  package = mkPnpmPackage {

    src = fetchFromGitHub {
      owner = "robertboloc";
      repo = "lolcatjs";
      rev = "a0baef18de64de2a794e1726fed89ad6b581aeec";
      sha256 = "1s922sy2irzjwj8xswanqd6q6dnwaxy252npq4h13yvx7dirgm31";
    };

    packageJSON = ./package.json;
    shrinkwrapYML = ./shrinkwrap.yaml;
  };

in package

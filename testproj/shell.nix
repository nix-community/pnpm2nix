with import <nixpkgs> { };

let
  pkg = import ./default.nix;

in mkShell {
  buildInputs = [ pkg ];
}

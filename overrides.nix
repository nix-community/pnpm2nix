{ pkgs, nodejs, nodePackages }:
with pkgs;

{
  sharp = (drv: drv.overrideAttrs(oldAttrs: {
    buildInputs = oldAttrs.buildInputs ++ (with pkgs; [
      vips
      glib
    ]);

    NIX_CFLAGS_COMPILE = [
      "-I${pkgs.glib.dev}/include/glib-2.0/"
      "-I${pkgs.glib}/lib/glib-2.0/include/"
    ];

    preBuild = ''
      # Force sharp to use the provided vips version
      # by default it tries to fetch it online
      echo 'module.exports.download_vips = function () { return true }' >> binding.js
    '';
  }));

  hiredis = (drv: drv.overrideAttrs(oldAttrs: {
    buildInputs = oldAttrs.buildInputs
      ++ lib.optional stdenv.isDarwin darwin.cctools;
  }));

  pkcs11js = (drv: drv.overrideAttrs(oldAttrs: {
    buildInputs = oldAttrs.buildInputs
      ++ lib.optional stdenv.isDarwin darwin.libobjc;
  }));
}

{
  lib,
  writeShellApplication,
  python3,
}:
writeShellApplication {
  name = "chrome-control";
  text = ''
    exec ${python3}/bin/python3 ${../scripts/chrome-control.py} "$@"
  '';
  meta = {
    description = "Recover native debugging in an existing Chrome profile";
    platforms = lib.platforms.darwin;
  };
}

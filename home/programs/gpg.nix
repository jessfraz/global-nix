{
  config,
  pkgs,
  ...
}: let
  pinentryPkg =
    if pkgs.stdenv.isLinux
    then pkgs.pinentry-tty
    else pkgs.pinentry_mac;
in {
  programs.gpg = {
    enable = true;

    homedir = "${config.home.homeDirectory}/.gnupg";

    settings = {
      default-key = "0x18F3685C0022BFF3";
      # Disable inclusion of the version string in ASCII armored output
      no-emit-version = true;
      # Disable comment string in clear text signatures and ASCII armored messages
      no-comments = true;
      # Display long key IDs
      keyid-format = "0xlong";
      # List all keys (or the specified ones) along with their fingerprints
      with-fingerprint = true;
      # Display the calculated validity of user IDs during key listings
      list-options = "show-uid-validity";
      verify-options = "show-uid-validity";

      # Try to use the GnuPG-Agent. With this option, GnuPG first tries to connect to
      # the agent before it asks for a passphrase.
      use-agent = true;

      charset = "utf-8";
      fixed-list-mode = true;

      personal-cipher-preferences = "AES256 AES192 AES CAST5";
      # list of personal digest preferences. When multiple ciphers are supported by
      # all recipients, choose the strongest one
      personal-digest-preferences = "SHA512 SHA384 SHA256 SHA224";
      # message digest algorithm used when signing a key
      cert-digest-algo = "SHA512";
      s2k-cipher-algo = "AES256";
      s2k-digest-algo = "SHA512";
      # This preference list is used for new keys and becomes the default for
      # "setpref" in the edit menu
      default-preference-list = "SHA512 SHA384 SHA256 SHA224 AES256 AES192 AES CAST5 ZLIB BZIP2 ZIP Uncompressed";
    };

    scdaemonSettings = {
      disable-ccid = true;
    };
  };

  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    pinentryPackage = pinentryPkg;

    defaultCacheTtl = 60;
    maxCacheTtl = 120;

    enableBashIntegration = true;
  };
}

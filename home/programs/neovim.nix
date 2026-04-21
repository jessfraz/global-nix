{lib, ...}: {
  programs.neovim.sideloadInitLua = lib.mkDefault true;
}

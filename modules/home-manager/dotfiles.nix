{ inputs, ... }:
{
  flake.modules.homeManager.gui.imports = [ inputs.dotfiles.homeManagerModules.default ];
}

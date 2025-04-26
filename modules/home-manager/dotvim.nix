{ inputs, ... }:
{
  flake.modules.homeManager.base.imports = [ inputs.dotvim.homeManagerModules.default ];
}

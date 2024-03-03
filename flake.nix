{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
  };

  outputs = { self, nixpkgs }:
  {
    nixosModules = {
      mkNixosConfigurations = import ./nixosModules/mkNixosConfigurations.nix nixpkgs.lib;
    };
  };
}
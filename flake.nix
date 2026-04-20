{
  description = "Fleet - minimal NixOS multi-host configuration library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    lib = import ./lib.nix nixpkgs.lib;
  };
}

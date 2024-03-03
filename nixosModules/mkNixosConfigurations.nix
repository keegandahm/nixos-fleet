lib:
{ # An attribute set mapping from hostnames to their system architecture.
  # Example:
  # {
  #   workstation = "x86_64-linux";
  #   rpi = "aarch64-linux";
  # }
  hosts,

  # The path to a folder containing host definitions. Each host
  # is a subdirectory under `hostsPath`, with a folder name matching
  # the hostname, containing .nix files that are dynamically loaded
  # and merged together.
  # The folder structure should look like this:
  #
  # /path/to/hostsPath/
  # ├── workstation/
  # │   ├── workstation.nix          # All .nix files in a host dir are auto
  # │   ├── configure-disks.nix      # loaded / merged to the final nixos module.
  # │   ├── enable-some-feature.nix
  # │   └── some-subdir-module/           # subdirs are auto loaded if they
  # │       ├── default.nix               # contain a file named default.nix.
  # │       └── some-supporting-file.nix  # Other files aren't.
  # └── rpi/
  #     ├── configuration.nix
  #     └── hardware.nix
  hostsPath,

  # Optional dir containing .nix files (or subdirs containing default.nix) that
  # are loaded and applied to *all* hosts. Each top-down module is expected to
  # take at least 1 arguments: { allNixosConfigs, fleetLib, hostname }, which
  # returns a nixos module.
  # E.g., the usual { pkgs, lib, config, ... }: { ... },
  # or a static attrs set, or a path.
  #
  # allNixosConfigs is a mapping from each hostname to the nixos configuration.
  #   e.g., for the host `workstation`,
  #   config  ==  allNixosConfigs.workstation.config
  # fleetLib is a set of library functions to help in collecting attributes and
  #   filtering hosts.
  #
  # For configs you only want to apply to a subset of hosts, you can use
  # lib.mkIf. For example:
  #   mkIf
  #     should-enable-remote-builds
  #     { # config built from build servers in `allNixosConfigs` }
  topDownModulesPath ? null,

  extraModules ? [ ],

  moduleArgs ? { },
}:

with lib;
with import ../fleetLib.nix { lib = lib; allSystemConfigs = null; hosts = null; };

let
  fleetLib = import ../fleetLib.nix { inherit lib allSystemConfigs hosts; };

  isModule = path: node: nodeType:
    ((nodeType == "regular" || nodeType == "symlink") && (builtins.match ".*\\.nix" node) != null)
    || (nodeType == "directory" && builtins.pathExists "${path}/${node}/default.nix");

  discoverModules = dir:
    filter notNull
      (mapAttrsToList
        (node: nodeType:
          if isModule dir node nodeType
          then dir + "/${node}"
          else null)
        (builtins.readDir dir));

  hostModules = mapAttrs (h: _: discoverModules (hostsPath + "/${h}")) hosts;

  topDownModules = if (notNull topDownModulesPath)
    then discoverModules topDownModulesPath
    else [ ];

  nixosSystemFromModules = hostname: system:
    nixosSystem {
      inherit system;

      modules = hostModules.${hostname};
      extraModules = extraModules ++ topDownModules;

      specialArgs = { inherit hostname allSystemConfigs fleetLib system; } // moduleArgs;
    };

  allSystemConfigs = mapAttrs nixosSystemFromModules hosts;
in

allSystemConfigs
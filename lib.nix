lib:

let
  # A directory entry is a loadable NixOS module if it is:
  # - a .nix file (regular or symlink), or
  # - a subdirectory containing a default.nix
  isModule = dir: name: type:
    ((type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name)
    || (type == "directory" && builtins.pathExists (dir + "/${name}/default.nix"));

  # Shared implementation for optionDir/optionSubDir.
  # Builds an option-value attrset from `entries` (a builtins.readDir result,
  # possibly pre-filtered). Recurses into plain subdirectories using the full
  # directory contents (filtering only applies at the top level).
  buildOptionTree = d: entries: args:
    lib.foldl lib.recursiveUpdate {}
      (lib.mapAttrsToList (name: type:
        if (type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name then
          let raw = import (d + "/${name}");
          in { ${lib.removeSuffix ".nix" name} = if builtins.isFunction raw then raw args else raw; }
        else if type == "directory" && builtins.pathExists (d + "/${name}/default.nix") then
          let raw = import (d + "/${name}/default.nix");
          in { ${name} = if builtins.isFunction raw then raw args else raw; }
        else if type == "directory" then
          { ${name} = buildOptionTree (d + "/${name}") (builtins.readDir (d + "/${name}")) args; }
        else
          {}
      ) entries);

  fleet = rec {
    # Load all NixOS modules from a directory.
    # Returns a list of paths (one per .nix file or default.nix subdir).
    loadDirIf = pred: dir:
      lib.mapAttrsToList (name: _: dir + "/${name}")
        (lib.filterAttrs (name: type: pred name && isModule dir name type)
          (builtins.readDir dir));

    loadDir = loadDirIf (_: true);

    subDir = loadDirIf (path: path != "default.nix");

    # Load all modules for a single host from its directory.
    # Named alias for loadDir; exists for clarity at call sites.
    loadHostDir = fleet.loadDir;

    # Discover all subdirectories of hostsPath and load their modules.
    # Returns { hostname = [module, ...]; } for every subdirectory found.
    # Every subdirectory is treated as a host — use loadHostDir directly
    # if you need finer control over which hosts are included.
    loadHostsDir = hostsPath:
      lib.mapAttrs (name: _: fleet.loadDir (hostsPath + "/${name}"))
        (lib.filterAttrs (_: type: type == "directory")
          (builtins.readDir hostsPath));

    # Generate a NixOS module from a directory that mirrors the NixOS option tree.
    #
    # Each .nix file becomes an option assignment at the path implied by its
    # location. Files may be a plain value or a function taking module args:
    #
    #   virtualisation/libvirtd.nix  →  { virtualisation.libvirtd = <value>; }
    #   services/openssh.nix         →  { services.openssh = <value>; }
    #
    # Subdirectories without a default.nix are descended into recursively.
    # Subdirectories WITH a default.nix are imported as a single value at
    # that path (the default.nix may also be a function taking module args).
    #
    # Files must return option values (attrsets, lists, strings, bools, etc.),
    # not full NixOS modules. Cross-cutting config that touches multiple option
    # paths belongs in a regular module loaded via loadDir instead.
    optionDir = dir: args@{ ... }:
      buildOptionTree dir (builtins.readDir dir) args;

    # Like optionDir, but excludes default.nix from the top-level entries.
    # Intended for use inside a default.nix that wants to delegate to its
    # siblings as option values without importing itself:
    #
    #   # services/default.nix
    #   args: fleetLib.optionSubDir ./. args
    optionSubDir = dir: args@{ ... }:
      buildOptionTree dir
        (lib.filterAttrs (name: _: name != "default.nix") (builtins.readDir dir))
        args;

    # Build a nested attrset of module paths from a directory tree.
    #
    # Each .nix file becomes an attribute named after the file (without .nix).
    # Directories with a default.nix become a single path at that name.
    # Directories without a default.nix are recursed into.
    # default.nix at any level is excluded from the tree (it is the container's
    # own module, not a named child).
    #
    # Intended use: pass the result as a specialArg so host configs can write
    #   imports = [ modules.packagesets.media modules.classes.interactive ];
    moduleTree = dir:
      let
        entries = lib.filterAttrs (name: type:
          name != "default.nix" && (
            ((type == "regular" || type == "symlink") && lib.hasSuffix ".nix" name)
            || type == "directory"
          )
        ) (builtins.readDir dir);
      in
      lib.mapAttrs' (name: type:
        let path = dir + "/${name}"; in
        lib.nameValuePair
          (lib.removeSuffix ".nix" name)
          (if type == "directory" && builtins.pathExists (path + "/default.nix")
           then (import path)
           else if type == "directory"
           then moduleTree path
           else (import path))
      ) entries;

    # Build a nixosConfigurations attrset.
    #
    # hosts        — { hostname = [module, ...]; }
    #                Each host must set nixpkgs.hostPlatform in its modules.
    # extraModules — modules applied to every host
    # moduleArgs   — extra specialArgs passed to every module
    #
    # Every module receives as specialArgs:
    #   hostname        — the host's name (string)
    #   allNixosConfigs — the full { hostname = nixosSystem; } map (lazy)
    #   fleetLib        — cross-host query helpers (see below)
    mkNixosConfigurations = {
      hosts,
      extraModules ? [],
      moduleArgs ? {},
    }:
    let
      fleetLib = {
        # Filter the set of all host configs by a predicate on nixosSystem objects.
        # Example: fleetLib.filteredConfigs (c: c.config.keegan.remoteBuilds.server.enable)
        filteredConfigs = pred:
          builtins.filter pred (lib.attrValues allNixosConfigs);

        # Collect a nested attribute (as a path list) from every host config
        # that has it. Useful for building lists from cross-host data, e.g.:
        #   fleetLib.collectValues ["config" "keegan" "remoteBuilds" "server" "machineConf"]
        #                          (fleetLib.filteredConfigs (c: c.config.keegan.remoteBuilds.server.enable))
        collectValues = path: configs:
          map (lib.getAttrFromPath path)
            (builtins.filter (lib.hasAttrByPath path) configs);

        inherit loadDir subDir optionDir optionSubDir moduleTree;
      };

      allNixosConfigs = lib.mapAttrs (hostname: hostModules:
        lib.nixosSystem {
          modules = hostModules ++ extraModules;
          specialArgs = { inherit hostname allNixosConfigs fleetLib; } // moduleArgs;
        }
      ) hosts;
    in
    allNixosConfigs;

  };
in
fleet

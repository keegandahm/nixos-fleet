{ lib, allSystemConfigs, hosts }:

with lib;

let
  hostConfigs = builtins.attrValues allSystemConfigs;
in

rec {
  notNull = v: v != null;
  valueOr = v: default: if v != null then v else default;

  hasPath = path: attrs:
    let head = builtins.head path; in
    if builtins.length path == 0 then true
    else attrs ? "${head}" && hasPath (builtins.tail path) attrs."${head}";

  getValueAtPath = path: attrs:
    foldl' (set: attr: set."${attr}") attrs path;

  collectValues = path: configs:
    map (getValueAtPath path) (filter (hasPath path) configs);

  #
  # The following functions depend on `allSystemConfigs` and `hosts`
  #
  allArchs = unique (builtins.attrValues hosts);
  filteredConfigs = filter: builtins.filter filter hostConfigs;
}
{ pkgs, config, options, lib, utils, ... }:

let
  inherit (lib)
    hasPrefix
    removePrefix
    attrNames
    attrValues
    mapAttrsToList
    zipAttrsWith
    flatten
    mkAfter
    mkOption
    mkIf
    mkMerge
    types
    foldl'
    unique
    concatMap
    concatMapStrings
    escapeShellArg
    escapeShellArgs
    recursiveUpdate
    all
    filter
    filterAttrs
    concatStringsSep
    catAttrs
    optionals
    optionalString
    literalExpression
    elem
    intersectLists
    any
    id
    ;

  inherit (types)
    attrsOf
    submodule
    ;

  inherit (lib.modules)
    importApply
    ;

  inherit (utils)
    escapeSystemdPath
    pathsNeededForBoot
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    parentsOf
    duplicates
    ;

  inherit (config.users) users;

  cfg = config.environment.persistence;

  # All persistent storage path submodule values zipped together into
  # one set. This includes paths from the Home Manager persistence
  # module and `users` submodules.
  allPersistentStoragePaths =
    let
      # All enabled system paths
      nixos = filter (v: v.enable) (attrValues cfg);

      # Get the files and directories from the `users` submodules of
      # enabled system paths
      nixosUsers = flatten (map attrValues (catAttrs "users" nixos));

      # Fetch enabled paths from all Home Manager users who have the
      # persistence module loaded
      homeManager =
        let
          paths = flatten
            (mapAttrsToList
              (_name: value:
                attrValues (value.home.persistence or { }))
              config.home-manager.users or { });
        in
        filter (v: v.enable) paths;
    in
    zipAttrsWith (_: flatten) (nixos ++ nixosUsers ++ homeManager);

    # A path is shadowed when it sits inside another persisted directory
    # AND resolves into the same persistent subtree: the ancestor's
    # symlink already makes the child appear exactly where its own link
    # would point. Linking it anyway traverses the ancestor's symlink and
    # plants a self-referential link inside persistent storage; running
    # the child first on a fresh boot instead materialises the ancestor
    # as a real ephemeral directory, failing its non-empty check. Nesting
    # across *different* storage roots is deliberately kept: that link
    # lands inside the ancestor's persistent copy but points at the other
    # root, which persists and resolves fine.
    shadowedBy = childPath: child: parent:
      parent.dirPath != childPath
      && hasPrefix "${parent.dirPath}/" childPath
      && concatPaths [ child.persistentStoragePath childPath ]
         == (concatPaths [ parent.persistentStoragePath parent.dirPath ]
             + removePrefix parent.dirPath childPath);

    directories =
      filter
        (d: !(any (shadowedBy d.dirPath d) allPersistentStoragePaths.directories))
        allPersistentStoragePaths.directories;

    files =
      filter
        (f: !(any (shadowedBy f.filePath f) directories))
        allPersistentStoragePaths.files;

  mountFile = pkgs.runCommand "persistence-mount-file" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./mount-file.bash} $out
    patchShebangs $out
  '';

  mkPersistFile = { filePath, persistentStoragePath, method, enableDebugging, ... }:
    let
      mountPoint = filePath;
      targetFile = concatPaths [ persistentStoragePath filePath ];
      args = escapeShellArgs [
        mountPoint
        targetFile
        method
        enableDebugging
      ];
    in
    ''
      ${mountFile} ${args}
    '';

  linkDirectory = pkgs.runCommand "persistence-link-directory" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./link-directory.bash} $out
    patchShebangs $out
  '';

  mkPersistDir = { dirPath, persistentStoragePath, user, group, mode, enableDebugging, ... }:
    let
      mountPoint = dirPath;
      targetDir = concatPaths [ persistentStoragePath dirPath ];
      args = escapeShellArgs [
        targetDir
        mountPoint
        user
        # Home Manager doesn't seem to know about the user's group
        (if group == null then users.${user}.group else group)
        mode
        enableDebugging
      ];
    in
    ''
      ${linkDirectory} ${args}
    '';

  defaultPerms = {
    mode = "0755";
    user = "root";
    group = "root";
  };
in
{
  options = {
    environment.persistence = mkOption {
      default = { };
      type =
        attrsOf (
          submodule [
            ({ name, config, ... }:
              (importApply ./submodule-options.nix {
                inherit pkgs lib name config;
                user = "root";
                group = "root";
                homeDir = null;
              }))
            ({ name, config, ... }:
              {
                options = {
                  users =
                    let
                      outerName = name;
                      outerConfig = config;
                    in
                    mkOption {
                      type = attrsOf (
                        submodule (
                          { name, config, ... }:
                          importApply ./submodule-options.nix {
                            inherit pkgs lib;
                            config = outerConfig // config;
                            name = outerName;
                            usersOpts = true;
                            user = name;
                            group = users.${name}.group;
                            homeDir = users.${name}.home;
                          }
                        )
                      );
                      default = { };
                      description = ''
                        A set of user submodules listing the files and
                        directories to link to their respective user's
                        home directories.

                        Each attribute name should be the name of the
                        user.

                        For detailed usage, check the <link
                        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
                      '';
                      example = literalExpression ''
                        {
                          talyz = {
                            directories = [
                              "Downloads"
                              "Music"
                              "Pictures"
                              "Documents"
                              "Videos"
                              "VirtualBox VMs"
                              { directory = ".gnupg"; mode = "0700"; }
                              { directory = ".ssh"; mode = "0700"; }
                              { directory = ".nixops"; mode = "0700"; }
                              { directory = ".local/share/keyrings"; mode = "0700"; }
                              ".local/share/direnv"
                            ];
                            files = [
                              ".screenrc"
                            ];
                          };
                        }
                      '';
                    };
                };
              })
          ]
        );
      description = ''
        A set of persistent storage location submodules listing the
        files and directories to link to their respective persistent
        storage location.

        Each attribute name should be the full path to a persistent
        storage location.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
      example = literalExpression ''
        {
          "/persistent" = {
            directories = [
              "/var/log"
              "/var/lib/bluetooth"
              "/var/lib/nixos"
              "/var/lib/systemd/coredump"
              "/etc/NetworkManager/system-connections"
              { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
            ];
            files = [
              "/etc/machine-id"
              { file = "/etc/nix/id_rsa"; parentDirectory = { mode = "u=rwx,g=,o="; }; }
            ];
          };
          users.talyz = { ... }; # See the dedicated example
        }
      '';
    };
  };

  config =
    mkMerge [
      (lib.optionalAttrs (options ? home-manager.sharedModules) {
        home-manager.sharedModules = [
          ./home-manager.nix
          {
            home._nixosModuleImported = true;
          }
        ];
      })
      (mkIf (allPersistentStoragePaths != { })
        (mkMerge [
          {
            systemd.services =
              let
                mkPersistFileService = { filePath, persistentStoragePath, ... }@args:
                  let
                    targetFile = concatPaths [ persistentStoragePath filePath ];
                    mountPoint = escapeShellArg filePath;
                  in
                  {
                    "persist-${escapeSystemdPath targetFile}" = {
                      description = "Bind mount or link ${targetFile} to ${mountPoint}";
                      wantedBy = [ "local-fs.target" ];
                      before = [ "local-fs.target" ];
                      after = [ "systemd-sysusers.service" ];
                      path = [ pkgs.util-linux ];
                      unitConfig.DefaultDependencies = false;
                      restartIfChanged = false;
                      serviceConfig = {
                        Type = "oneshot";
                        RemainAfterExit = true;
                        ExecStart = mkPersistFile args;
                        ExecStop = pkgs.writeShellScript "unbindOrUnlink-${escapeSystemdPath targetFile}" ''
                          set -eu
                          if [[ -L ${mountPoint} ]]; then
                              rm ${mountPoint}
                          else
                              umount ${mountPoint}
                              rm ${mountPoint}
                          fi
                        '';
                      };
                    };
                  };

                mkPersistDirService = { dirPath, persistentStoragePath, ... }@args:
                  let
                    targetDir = concatPaths [ persistentStoragePath dirPath ];
                    mountPoint = escapeShellArg dirPath;
                  in
                  {
                    "persist-${escapeSystemdPath targetDir}" = {
                      description = "Link ${targetDir} to ${mountPoint}";
                      wantedBy = [ "local-fs.target" ];
                      before = [ "local-fs.target" ];
                      after = [ "systemd-sysusers.service" ];
                      path = [ pkgs.util-linux ];
                      unitConfig.DefaultDependencies = false;
                      restartIfChanged = false;
                      serviceConfig = {
                        Type = "oneshot";
                        RemainAfterExit = true;
                        ExecStart = mkPersistDir args;
                        # The directory is only ever a symlink now, but an
                        # older generation may have left behind a bind mount.
                        ExecStop = pkgs.writeShellScript "unlink-${escapeSystemdPath targetDir}" ''
                          set -eu
                          if [[ -L ${mountPoint} ]]; then
                              rm ${mountPoint}
                          elif findmnt ${mountPoint} >/dev/null; then
                              umount ${mountPoint}
                          fi
                        '';
                      };
                    };
                  };
              in
              foldl' recursiveUpdate { }
                ((map mkPersistFileService files)
                  ++ (map mkPersistDirService directories));

            boot.initrd.systemd.services =
              let
                mkPersistDirInitrdService = { dirPath, persistentStoragePath, mode, ... }:
                  let
                    targetDir = concatPaths [ persistentStoragePath dirPath ];
                    # In the initrd the ephemeral root and persistent storage
                    # live under /sysroot, but the symlink has to resolve
                    # after the switch_root, so it points at the final path.
                    sysrootTarget = concatPaths [ "/sysroot" targetDir ];
                    sysrootTargetParent = builtins.dirOf sysrootTarget;
                    sysrootMountPoint = concatPaths [ "/sysroot" dirPath ];
                    sysrootParent = builtins.dirOf sysrootMountPoint;
                  in
                  {
                    "persist-${escapeSystemdPath targetDir}" = {
                      description = "Link ${targetDir} to ${dirPath}";
                      wantedBy = [ "initrd.target" ];
                      before = [ "initrd-nixos-activation.service" ];
                      unitConfig = {
                        DefaultDependencies = false;
                        # Order after the persistent storage is mounted.
                        RequiresMountsFor = [ sysrootTarget ];
                      };
                      # The initrd only ships systemd's own tools; pull in
                      # coreutils for mkdir/ln. Using `script` (rather than an
                      # external ExecStart) is what gets the generated script
                      # copied into the initramfs.
                      path = [ pkgs.coreutils ];
                      serviceConfig = {
                        Type = "oneshot";
                        RemainAfterExit = true;
                      };
                      # Ownership is applied later, in the stage-2
                      # `persist-directories` activation, once users exist; the
                      # initrd only needs the directory to be present.
                      # `mkdir --mode` and `-p` are split so we don't trip
                      # shellcheck's SC2174 (mode only applies to the deepest
                      # dir under -p), which is fatal under strict shell checks.
                      script = ''
                        if [ ! -d ${escapeShellArg sysrootTarget} ]; then
                            mkdir -p ${escapeShellArg sysrootTargetParent}
                            mkdir --mode=${escapeShellArg mode} ${escapeShellArg sysrootTarget}
                        fi
                        mkdir -p ${escapeShellArg sysrootParent}
                        if [ ! -e ${escapeShellArg sysrootMountPoint} ]; then
                            ln -s ${escapeShellArg targetDir} ${escapeShellArg sysrootMountPoint}
                        fi
                      '';
                    };
                  };
                dirs = filter (d: elem d.dirPath pathsNeededForBoot) directories;
              in
              foldl' recursiveUpdate { } (map mkPersistDirInitrdService dirs);

            system.activationScripts =
              let
                # Script to create directories in persistent and ephemeral
                # storage. The directory structure's mode and ownership mirror
                # those of persistentStoragePath/dir.
                createDirectories = pkgs.runCommand "persistence-create-directories" { buildInputs = [ pkgs.bash ]; } ''
                  cp ${./create-directories.bash} $out
                  patchShebangs $out
                '';

                mkDirWithPerms =
                  { dirPath
                  , persistentStoragePath
                  , user
                  , group
                  , mode
                  , enableDebugging
                  , ...
                  }:
                  let
                    args = [
                      persistentStoragePath
                      dirPath
                      user
                      # Home Manager doesn't seem to know about the user's group
                      (if group == null then users.${user}.group else group)
                      mode
                      enableDebugging
                    ];
                  in
                  ''
                    ${createDirectories} ${escapeShellArgs args}
                  '';

                # Build an activation script which creates all persistent
                # storage directories we want to bind mount.
                dirCreationScript =
                  let
                    # The parent directories of files.
                    fileDirs = unique (catAttrs "parentDirectory" files);

                    # All the directories actually listed by the user and the
                    # parent directories of listed files.
                    explicitDirs = directories ++ fileDirs;

                    # Home directories have to be handled specially, since
                    # they're at the permissions boundary where they
                    # themselves should be owned by the user and have stricter
                    # permissions than regular directories, whereas its parent
                    # should be owned by root and have regular permissions.
                    #
                    # This simply collects all the home directories and sets
                    # the appropriate permissions and ownership.
                    homeDirs =
                      foldl'
                        (state: dir:
                          let
                            homeDir = {
                              directory = dir.home;
                              dirPath = dir.home;
                              home = null;
                              mode = "0700";
                              user = dir.user;
                              group = users.${dir.user}.group;
                              inherit defaultPerms;
                              inherit (dir) persistentStoragePath enableDebugging;
                            };
                          in
                          if dir.home != null then
                            if !(elem homeDir state) then
                              state ++ [ homeDir ]
                            else
                              state
                          else
                            state
                        )
                        [ ]
                        explicitDirs;

                    # Persistent storage directories. These need to be created
                    # unless they're at the root of a filesystem.
                    persistentStorageDirs =
                      foldl'
                        (state: dir:
                          let
                            persistentStorageDir = {
                              directory = dir.persistentStoragePath;
                              dirPath = dir.persistentStoragePath;
                              persistentStoragePath = "";
                              home = null;
                              inherit (dir) defaultPerms enableDebugging;
                              inherit (dir.defaultPerms) user group mode;
                            };
                          in
                          if dir.home == null && !(elem persistentStorageDir state) then
                            state ++ [ persistentStorageDir ]
                          else
                            state
                        )
                        [ ]
                        (explicitDirs ++ homeDirs);

                    # Generate entries for all parent directories of the
                    # argument directories, listed in the order they need to
                    # be created. The parent directories are assigned default
                    # permissions.
                    mkParentDirs = dirs:
                      let
                        # Create a new directory item from `dir`, the child
                        # directory item to inherit properties from and
                        # `path`, the parent directory path.
                        mkParent = dir: path: {
                          directory = path;
                          dirPath =
                            if dir.home != null then
                              concatPaths [ dir.home path ]
                            else
                              path;
                          inherit (dir) persistentStoragePath home enableDebugging;
                          inherit (dir.defaultPerms) user group mode;
                        };
                        # Create new directory items for all parent
                        # directories of a directory.
                        mkParents = dir:
                          map (mkParent dir) (parentsOf dir.directory);
                      in
                      unique (flatten (map mkParents dirs));

                    persistentStorageDirParents = mkParentDirs persistentStorageDirs;

                    # Parent directories of home folders. This is usually only
                    # /home, unless the user's home is in a non-standard
                    # location.
                    homeDirParents = mkParentDirs homeDirs;

                    # Parent directories of all explicitly listed directories.
                    parentDirs = mkParentDirs explicitDirs;

                    # All directories in the order they should be created.
                    # The explicitly listed `directories` are deliberately
                    # left out: they become symlinks into persistent storage
                    # rather than real directories in the ephemeral
                    # filesystem, and are handled by `persist-directories`.
                    # Their parents and the parent directories of files
                    # (`fileDirs`) still need to be real directories, though.
                    allDirs =
                      persistentStorageDirParents
                      ++ persistentStorageDirs
                      ++ homeDirParents
                      ++ homeDirs
                      ++ parentDirs
                      ++ fileDirs;
                  in
                  pkgs.writeShellScript "persistence-run-create-directories" ''
                    _status=0
                    trap "_status=1" ERR
                    ${concatMapStrings mkDirWithPerms allDirs}
                    exit $_status
                  '';

                persistFileScript =
                  pkgs.writeShellScript "persistence-persist-files" ''
                    _status=0
                    trap "_status=1" ERR
                    ${concatMapStrings mkPersistFile files}
                    exit $_status
                  '';

                persistDirScript =
                  pkgs.writeShellScript "persistence-persist-directories" ''
                    _status=0
                    trap "_status=1" ERR
                    ${concatMapStrings mkPersistDir directories}
                    exit $_status
                  '';
              in
              {
                "createPersistentStorageDirs" = {
                  deps = [ "users" "groups" ];
                  text = "${dirCreationScript}";
                };
                "persist-directories" = {
                  deps = [ "createPersistentStorageDirs" ];
                  text = "${persistDirScript}";
                };
                "persist-files" = {
                  deps = [ "createPersistentStorageDirs" "persist-directories" ];
                  text = "${persistFileScript}";
                };
              };

            boot.initrd.postMountCommands =
              let
                neededForBootDirs = filter (dir: elem dir.dirPath pathsNeededForBoot) directories;
                mkSymlink = { persistentStoragePath, dirPath, ... }:
                  let
                    # In the stage-1 initrd the ephemeral root is mounted at
                    # /mnt-root; the symlink target has to resolve after the
                    # switch_root, so it points at the final path.
                    target = concatPaths [ "/mnt-root" persistentStoragePath dirPath ];
                    mountPoint = concatPaths [ "/mnt-root" dirPath ];
                  in
                  ''
                    mkdir -p ${escapeShellArg target}
                    mkdir -p "$(dirname ${escapeShellArg mountPoint})"
                    if [ ! -e ${escapeShellArg mountPoint} ]; then
                        ln -s ${escapeShellArg (concatPaths [ persistentStoragePath dirPath ])} ${escapeShellArg mountPoint}
                    fi
                  '';
              in
              mkIf (!config.boot.initrd.systemd.enable)
                (mkAfter (concatMapStrings mkSymlink neededForBootDirs));
          }

          # Work around an issue with persisting /etc/machine-id where the
          # systemd-machine-id-commit.service unit fails if the final
          # /etc/machine-id is bind mounted from persistent storage. For
          # more details, see
          # https://github.com/nix-community/impermanence/issues/229 and
          # https://github.com/nix-community/impermanence/pull/242
          (mkIf (any (f: f == "/etc/machine-id") (catAttrs "filePath" files)) {
            boot.initrd.systemd.suppressedUnits = [ "systemd-machine-id-commit.service" ];
            systemd.services.systemd-machine-id-commit.unitConfig.ConditionFirstBoot = true;
          })

          # Assertions and warnings
          {
            assertions =
              let
                markedNeededForBoot = cond: fs:
                  if config.fileSystems ? ${fs} then
                    config.fileSystems.${fs}.neededForBoot == cond
                  else
                    cond;

                persistentStoragePaths = unique (catAttrs "persistentStoragePath" (files ++ directories));

                submoduleAssertions = flatten allPersistentStoragePaths.assertions;

                fileAssertions = flatten (catAttrs "assertions" files);

                directoryAssertions = flatten (catAttrs "assertions" directories);

                filePaths = catAttrs "filePath" files;
                duplicateFiles = duplicates filePaths;

                dirPaths = catAttrs "dirPath" directories;
                duplicateDirs = duplicates dirPaths;

                allPaths = unique (concatMap parentsOf (filePaths ++ dirPaths));
              in
              submoduleAssertions
              ++ fileAssertions
              ++ directoryAssertions
              ++ [
                {
                  # Assert that all persistent storage volumes we use are
                  # marked with neededForBoot.
                  assertion = all (markedNeededForBoot true) persistentStoragePaths;
                  message =
                    let
                      offenders = filter (markedNeededForBoot false) persistentStoragePaths;
                    in
                    ''
                      environment.persistence:
                          All filesystems used for persistent storage must
                          have the option "neededForBoot" set to true.

                          Please fix the following filesystems:
                            ${concatStringsSep "\n      " offenders}
                    '';
                }
                {
                  # Assert that all ephemeral storage volumes we
                  # create links into are marked with neededForBoot.
                  assertion = all (markedNeededForBoot true) allPaths;
                  message =
                    let
                      offenders = filter (markedNeededForBoot false) allPaths;
                    in
                    ''
                      environment.persistence:
                          All filesystems used for ephemeral storage must
                          have the option "neededForBoot" set to true.

                          Please fix the following filesystems:
                            ${concatStringsSep "\n      " offenders}
                    '';
                }
                {
                  assertion = duplicateFiles == [ ];
                  message = ''
                    environment.persistence:
                        The following files were specified two or more
                        times:
                          ${concatStringsSep "\n      " duplicateFiles}
                  '';
                }
                {
                  assertion = duplicateDirs == [ ];
                  message = ''
                    environment.persistence:
                        The following directories were specified two or more
                        times:
                          ${concatStringsSep "\n      " duplicateDirs}
                  '';
                }
              ];

            warnings =
              let
              shadowedDirs =
                let raw = allPersistentStoragePaths.directories;
                in filter (d: any (shadowedBy d.dirPath d) raw) raw;
              usersWithoutUid = attrNames (filterAttrs (n: u: u.uid == null) config.users.users);                groupsWithoutGid = attrNames (filterAttrs (n: g: g.gid == null) config.users.groups);
                varLibNixosPersistent =
                  let
                    varDirs = parentsOf "/var/lib/nixos" ++ [ "/var/lib/nixos" ];
                    persistedDirs = catAttrs "dirPath" directories;
                    mountedDirs = catAttrs "mountPoint" (attrValues config.fileSystems);
                    persistedVarDirs = intersectLists varDirs persistedDirs;
                    mountedVarDirs = intersectLists varDirs mountedDirs;
                  in
                  persistedVarDirs != [ ] || mountedVarDirs != [ ];
              in
              mkIf (any id allPersistentStoragePaths.enableWarnings)
                (mkMerge [
                  (mkIf (shadowedDirs != [ ]) [
                    ''
                      environment.persistence:
                          The following directories are nested inside another persisted
                          directory and have been skipped; they are already persistent
                          through their ancestor:
                            ${concatStringsSep "\n      " (unique (catAttrs "dirPath" shadowedDirs))}
                    ''
                  ])
                  (mkIf (!varLibNixosPersistent && (usersWithoutUid != [ ] || groupsWithoutGid != [ ])) [
                    ''
                      environment.persistence:
                          Neither /var/lib/nixos nor any of its parents are
                          persisted. This means all users/groups without
                          specified uids/gids will have them reassigned on
                          reboot.
                          ${optionalString (usersWithoutUid != [ ]) ''
                          The following users are missing a uid:
                                ${concatStringsSep "\n      " usersWithoutUid}
                          ''}
                          ${optionalString (groupsWithoutGid != [ ]) ''
                          The following groups are missing a gid:
                                ${concatStringsSep "\n      " groupsWithoutGid}
                          ''}
                    ''
                  ])
                ]);
          }
        ]))
    ];

}

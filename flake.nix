{
  description = "A Nix flake for building the Zig program 'acns'";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
    nix2zon.url = "github:ninofaivre/nix2zon";
    nixpkgs.url = "nixpkgs/release-25.05";
  };

  outputs = { zig2nix, nix2zon, nixpkgs, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
    inherit (nix2zon.lib) toZon;
    name = "acns";
    package = (flake-utils.lib.eachDefaultSystem (system: let
      env = zig2nix.outputs.zig-env.${system} {
        inherit nixpkgs;
        zig = zig2nix.outputs.packages.${system}.zig-master;
      };
      version = "0.0.1";
      zigDeps = import ./nix/deps.nix {inherit (env.pkgs) fetchFromGitHub;};
    in with builtins; with env.pkgs.lib; rec {
      # nix build .#foreign
      packages.foreign = env.package {
        meta.mainProgram = name;
        inherit name;
        inherit version;
        src = cleanSource ./.;

        nativeBuildInputs = with env.pkgs; [
          glibc.dev
          libnl.dev
          linuxHeaders
          autoPatchelfHook
        ] ++ attrValues zigDeps;

        buildInputs = with env.pkgs; [
          libnftnl
          libmnl
        ];

        /* TODO
          zig-libc.txt was not needed with the older version of zig-0.15.0
          need to figure out why it is now needed to use the correct libc
          and not fail at linking stage. It is still not needed in devshell
          while building with 'zig build' but somehow is needed for the build
          stage of zig2nix.
        */
        preBuild = ''
          # Créer le fichier de config libc pour Zig
          >zig-libc.txt cat <<< '
          include_dir=${env.pkgs.glibc.dev}/include
          sys_include_dir=${env.pkgs.linuxHeaders}/include
          crt_dir=${env.pkgs.glibc}/lib
          msvc_lib_dir=
          kernel32_lib_dir=
          gcc_dir=;
          '
          # Forcer Zig à utiliser ce fichier
          export ZIG_LIBC=$PWD/zig-libc.txt

          rm -rf deps
          mkdir deps
          ${concatMapStrings (value: ''
            ln -s ${value} ./deps/${removePrefix "/nix/store/" value}
          '')  (attrValues zigDeps)}
          >build.zig.zon cat <<< '${toZon { value = {
            name = ".${name}";
            fingerprint = "0xda3d5caca4187a84";
            inherit version;
            paths = [ "src" "build.zig" ];
            dependencies = mapAttrs (name: value: {
              path = "\\./deps/${removePrefix "/nix/store/" value}/";
            }) zigDeps;
          }; }}'
        '';

        zigPreferMusl = false;
      };

      # nix build .
      packages.default = packages.foreign.override (attrs: {
        # Executables required for runtime
        # These packages will be added to the PATH
        zigWrapperBins = with env.pkgs; [];

        # Libraries required for runtime
        # These packages will be added to the LD_LIBRARY_PATH
        zigWrapperLibs = attrs.buildInputs or [];
      });

      packages.${name} = packages.default;

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/master";
      };

      # nix run .
      apps.default = env.app [] "zig build run -- \"$@\"";

      # nix run .#build
      apps.build = env.app [] "zig build \"$@\"";

      # nix run .#test
      apps.test = env.app [] "zig build test -- \"$@\"";

      # nix run .#docs
      apps.docs = env.app [] "zig build docs -- \"$@\"";

      # nix run .#zig2nix
      apps.zig2nix = env.app [] "zig2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        shellHook = ''
          export PATH="''${PATH}:''${PWD}/zig-out/bin"
          alias build="zig build"
          alias b="build"
          ${packages.foreign.preBuild}
        '';
        nativeBuildInputs = [
            (import ./nix/simpleClient.sh.nix {
              inherit (env) pkgs;
              projectName = name;
            })
          ]
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
      };
    }));
  in ({
      nixosModules.${name} = (import ./nix/nixosModule.nix {
        acnsSystemPkgs = package.packages;
        inherit toZon;
      });
    } // package);
}

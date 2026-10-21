{
  description = "A Nix flake for building the Zig program 'acns'";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
    nix2zon.url = "github:ninofaivre/nix2zon";
    nixpkgs.url = "nixpkgs/release-25.05";
    nixpkgs26.url = "nixpkgs/release-26.05";
  };

  outputs = { self, zig2nix, nix2zon, nixpkgs, nixpkgs26, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
    name = "acns";
    systems = with flake-utils.lib.system; [
      x86_64-linux
    ];
    package = (flake-utils.lib.eachSystem systems (system: let
      env = zig2nix.outputs.zig-env.${system} {
        inherit nixpkgs;
        zig = zig2nix.outputs.packages.${system}.zig-latest;
      };
      acnsTestClient = (import ./nix/testClient.sh.nix {
        inherit (env) pkgs;
        projectName = name;
      });
      version = "0.0.1";
    in with env.pkgs.lib; rec {
      packages.foreign = let
        sources = [ ./src ./build.zig ];
      in env.package {
        meta.mainProgram = name;
        inherit name;
        inherit version;
        src = fileset.toSource {
          root = ./.;
          fileset = fileset.unions sources;
        };

        nativeBuildInputs = with env.pkgs; [
          glibc.dev
          libnl.dev
        ];

        buildInputs = with env.pkgs; [
          libnftnl
          libmnl
        ];

        zigTarget = "${system}-gnu.${env.pkgs.glibc.version}";
        preBuild = nix2zon.lib.genBuildZig { inherit (env.pkgs) linkFarm; } {
          name = ".${name}";
          fingerprint = "0xda3d5caca4187a84";
          inherit version;
          paths = sources ++ [ "build.zig.zon" ];
          dependencies = (import ./nix/deps.nix {
            inherit (env.pkgs) fetchFromGitHub;
          });
        };

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

      # nix run .
      apps.default = env.app [] "zig build run -- \"$@\"";

      # nix run .#build
      apps.build = env.app [] "zig build \"$@\"";

      # nix run .#test
      apps.test = env.app [] "zig build test -- \"$@\"";
      checks.e2e = (import nixpkgs26 { inherit system; }).testers.runNixOSTest (import ./nix/test.nix {
        acnsModule = self.nixosModules.acns;
        acnsPkg = packages.${name};
        inherit acnsTestClient;
      });
      packages.test-driver = checks.e2e.driver;


      # nix run .#docs
      apps.docs = env.app [] "zig build docs -- \"$@\"";

      # nix run .#zig2nix
      apps.zig2nix = env.app [] "zig2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        packages = [
          acnsTestClient
          (env.pkgs.writeShellApplication {
            name = "e2e";
            runtimeInputs = [ packages.test-driver ];
            text = /*bash*/ ''
              sudo ${getExe packages.test-driver} -I "$@" <<EOF
                machine.copy_from_host("./zig-out", "/")
                machine.execute("systemctl restart acns")
                test_script()
                exit()
              EOF
            '';
          })
          (env.pkgs.writeShellApplication {
            name = "build";
            text = /*bash*/ ''
              ${packages.foreign.preBuild}
              zig build \
                -Dtarget=${packages.default.zigTarget} \
                -Ddynamic-linker=${env.pkgs.stdenv.cc.bintools.dynamicLinker}
            '';
          })
        ];
        shellHook = ''
          export PATH="''${PATH}:''${PWD}/zig-out/bin"
          alias b="build"
        '';
        nativeBuildInputs = [
        ] ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
      };
    }));
  in ({
      nixosModules.${name} = (import ./nix/nixosModule.nix {
        acnsSystemPkgs = package.packages;
        toZon = nix2zon.lib.generators.toZon {
          suppressNullAttrValues = true;
        };
      });
    } // package);
}

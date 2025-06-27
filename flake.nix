{
  description = "A Nix flake for building the Zig program 'acn'";

  inputs = {
    nixpkgs.url = "nixpkgs/release-25.05";
    zigpkgs.url = "github:mitchellh/zig-overlay";
    nix2zon.url = "github:ninofaivre/nix2zon";
  };

  outputs = { self, zigpkgs, nixpkgs, nix2zon }:
    let
      system = "x86_64-linux";
      overlays = [
        (final: prev: {
          zig = zigpkgs.packages.${prev.system}.master.overrideAttrs (f: p: {
            meta = prev.zig.meta // zigpkgs.packages.${final.system}.master.meta;
          });
        })
      ];
      basePkgs = import nixpkgs { inherit system; };
      pkgs = import nixpkgs { inherit system overlays; };
      inherit (nixpkgs) lib;

      inherit (nix2zon.lib) toZon;

      name = "acns";
      version = "0.0.1";
      zigDeps = import ./nix/deps.nix { inherit (pkgs) fetchFromGitHub; };
    in {
      packages.${system}.${name} = pkgs.stdenv.mkDerivation {
        meta = {
          mainProgram = name;
        };
        inherit name;
        inherit version;
        src = ./.;

        zigBuildFlags = [];

        nativeBuildInputs = with pkgs; [
          basePkgs.zig.hook
          libnl.dev
          linuxHeaders
        ] ++ builtins.attrValues zigDeps;
        buildInputs = with pkgs; [
          libnftnl
          libnl.bin
          libmnl
        ];
        postPatch = ''
          rm -rf deps
          mkdir deps
          ${lib.strings.concatMapStrings (value: ''
            ln -s ${value} ./deps/${lib.removePrefix "/nix/store/" value}
          '')  (lib.attrsets.attrValues zigDeps)}
          >build.zig.zon cat <<< '${toZon { value = {
            name = ".${name}";
            fingerprint = "0xda3d5caca4187a84";
            inherit version;
            paths = [ "src" "build.zig" ];
            dependencies = builtins.mapAttrs (name: value: {
              path = "\\./deps/${lib.removePrefix "/nix/store/" value}/";
            }) zigDeps;
          }; }}'
        '';
      };

      defaultPackage.${system} = self.packages.${system}.${name};

      devShell.${system} = with self.packages.${system}; pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          zig
          (import ./nix/simpleClient.sh.nix {
            inherit pkgs;
            projectName = name;
          })
        ] ++ acns.buildInputs ++ builtins.filter (pkg: pkg != basePkgs.zig.hook) acns.nativeBuildInputs;
        shellHook = ''
          export PATH="''${PATH}:''${PWD}/zig-out/bin"
          alias build="zig build"
          alias b="build"
          ${acns.postPatch}
        '';
      };
    };
}

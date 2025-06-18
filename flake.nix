{
  description = "A Nix flake for building the Zig program 'acn'";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    nix2zon.url = "github:ninofaivre/nix2zon";
  };

  outputs = { self, nixpkgs, nix2zon }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;
      zigDeps = import ./nix/deps.nix { inherit (pkgs) fetchFromGitHub; };
      version = "0.0.1";
      inherit (nix2zon.lib) toZon;
    in {
      packages.${system}.acns = pkgs.stdenv.mkDerivation {
        meta = {
          mainProgram = "acns";
        };
        name = "acns";
        src = ./.;
        inherit version;

        zigBuildFlags = [];

        nativeBuildInputs = with pkgs; [
          zig.hook
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
            name = ".acns";
            fingerprint = "0xda3d5caca4187a84";
            inherit version;
            paths = [ "src" "build.zig" ];
            dependencies = builtins.mapAttrs (name: value: {
              path = "\\./deps/${lib.removePrefix "/nix/store/" value}/";
            }) zigDeps;
          }; }}'
        '';
      };

      defaultPackage.${system} = self.packages.${system}.acns;

      devShell.${system} = with self.packages.${system}; pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          zig
        ] ++ acns.buildInputs ++ builtins.filter (pkg: pkg != zig.hook) acns.nativeBuildInputs;
        shellHook = ''
          export PATH="''${PATH}:''${PWD}/zig-out/bin"
          alias build="zig build"
          alias b="build"
          ${acns.postPatch}
        '';
      };
    };
}

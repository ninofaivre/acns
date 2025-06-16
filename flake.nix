{
  description = "A Nix flake for building the Zig program 'acn'";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;
      zigPkgs = import ./nix/deps.nix { inherit (pkgs) fetchFromGitHub; };
      version = "0.0.1";
    in {
      packages."x86_64-linux".acns = pkgs.stdenv.mkDerivation {
        meta = {
          mainProgram = "acns";
        };
        name = "acns";
        src = ./.;
        inherit version;

        zigBuildFlags = [
          "-DabsoluteLibsPaths=${pkgs.libnftnl}/lib,${pkgs.libnl.out}/lib,${pkgs.libmnl}/lib"
          "-DabsoluteIncludesPaths=${pkgs.libnftnl}/include,${pkgs.libnl.dev}/include/libnl3,${pkgs.libmnl}/include,${pkgs.linuxHeaders}/include"
          "-Dversion=${version}"
        ];

        nativeBuildInputs = with pkgs; [
          zig.hook
          libnftnl
          libnl.dev
          libnl.bin
          libmnl
          linuxHeaders
        ] ++ builtins.attrValues zigPkgs;
        postPatch = ''
          >build.zig.zon cat <<< '${(import ./nix/utils/genZon.nix { inherit lib; }) {
            name = "acns";
            fingerprint = "0xda3d5caca4187a84";
            inherit version;
            paths = [ "src" "build.zig" ];
            inherit zigPkgs;
          }}'
        '';
        buildInputs = with pkgs; [
          libnftnl
          libnl.bin
          libmnl
        ];
      };

      defaultPackage.x86_64-linux = self.packages."x86_64-linux".acns;

      devShell.x86_64-linux = pkgs.mkShell {
        buildInputs = [
          self.packages."x86_64-linux".acns
        ];

        shellHook = ''
          echo "acns added to devshell path"
        '';
      };
    };
}

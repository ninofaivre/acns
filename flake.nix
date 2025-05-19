{
  description = "A Nix flake for building the Zig program 'acn'";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in {
      packages."x86_64-linux".acn = pkgs.stdenv.mkDerivation {
        name = "acn";
        src = ./.;

        zigBuildFlags = [
          "-DabsoluteLibsPaths=${pkgs.libnftnl}/lib,${pkgs.libnl.out}/lib,${pkgs.libmnl}/lib"
          "-DabsoluteIncludesPaths=${pkgs.libnftnl}/include,${pkgs.libnl.dev}/include/libnl3,${pkgs.libmnl}/include,${pkgs.linuxHeaders}/include"
        ];

        nativeBuildInputs = with pkgs; [
          zig.hook
          libnftnl
          libnl.dev
          libnl.bin
          libmnl
          linuxHeaders
        ];
        buildInputs = with pkgs; [
          libnftnl
          libnl.bin
          libmnl
        ];
      };

      defaultPackage.x86_64-linux = self.packages."x86_64-linux".acn;

      devShell.x86_64-linux = pkgs.mkShell {
        buildInputs = [
          self.packages."x86_64-linux".acn
        ];

        shellHook = ''
          echo "coucou"
        '';
      };
    };
}

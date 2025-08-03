{ fetchFromGitHub }:
{
  # use official repo (caeser) when zig 0.15.0 is released
  zli = fetchFromGitHub {
    owner = "ninofaivre";
    repo = "zli";
    rev = "763d758de6aead1287f011274ebd4c17c4010009";
    sha256 = "7w8FuHDmRKNaneCXV/G7yf4PAAgW/K+8y/O41dWQju4=";
  };
}

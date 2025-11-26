{ fetchFromGitHub }:
{
  zli = fetchFromGitHub {
    owner = "xcaeser";
    repo = "zli";
    rev = "v4.3.0";
    sha256 = "GdemJWkgSYsNK0Sqx7lMCWnv8/A0wBUtWjzEZH01Piw=";
  };
}

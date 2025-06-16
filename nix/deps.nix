{ fetchFromGitHub }:
{
  zli = fetchFromGitHub {
    owner = "xcaeser";
    repo = "zli";
    rev = "v3.7.0";
    sha256 = "2vQJRu7mL0vdotmih0ULi5UTvcsISTGifNdsmfX+/SY=";
  };
  yaml = fetchFromGitHub {
    owner = "kubkon";
    repo = "zig-yaml";
    rev = "0.1.1";
    sha256 = "HfxM1MgdlnnD13LG9AWULu/jy5zMRa3nkLUqkKj1RC4=";
  };
}

{ fetchFromGitHub }:
{
  zli = fetchFromGitHub {
    owner = "xcaeser";
    repo = "zli";
    rev = "v3.7.0";
    sha256 = "2vQJRu7mL0vdotmih0ULi5UTvcsISTGifNdsmfX+/SY=";
  };
}

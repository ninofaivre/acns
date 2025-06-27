{ fetchFromGitHub }:
{
  zli = fetchFromGitHub {
    owner = "xcaeser";
    repo = "zli";
    # not the latest version because latest version can't be build with
    # zig 0.15.0-dev, upgrade version when 0.15.0 release I guess
    rev = "v3.6.3";
    sha256 = "73ycow6OyDEtS1oVGi1eM/kdVOikR3/QgvWjZVqCb1Y=";
  };
}

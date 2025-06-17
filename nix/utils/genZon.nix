{ lib }:
{ name, fingerprint, version, paths, deps }: ''.{
  .name = .${name},
  .fingerprint = ${fingerprint},
  .version = "${version}",
  .paths = .{ ${lib.strings.concatMapStringsSep ", " (x: "\"${x}\"") paths} },
  .dependencies = .{
    ${lib.strings.concatMapStrings ({name, value}: ''
      .${name} = .{
        .path = "./deps/${lib.removePrefix "/nix/store/" value}/",
      },
    '') (lib.attrsets.attrsToList deps)}
  },
}''

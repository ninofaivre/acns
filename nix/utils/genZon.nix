{ lib }:
{ name, fingerprint, version, paths, zigPkgs }: ''.{
  .name = .${name},
  .fingerprint = ${fingerprint},
  .version = "${version}",
  .paths = .{ ${lib.strings.concatMapStringsSep ", " (x: "\"${x}\"") paths} },
  .dependencies = .{
    ${lib.strings.concatMapStrings ({name, value}: ''
      .${name} = .{
        .path = "../../${value}/",
      },
    '') (lib.attrsets.attrsToList zigPkgs)}
  },
}''

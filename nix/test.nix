{ acnsModule, acnsTestClient }:
{
  name = "end to end test";
  nodes.machine = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      acnsTestClient
    ];
    imports = [ acnsModule ];

    networking.nftables.enable = true;
    networking.nftables.tables."nixos-fw".content = ''
      set acnsTestTimeout.v4 {
        type ipv4_addr
        flags timeout
      }

      set acnsTest.v4 {
        type ipv4_addr
      }

      set acnsTestNoRight.v4 {
        type ipv4_addr
      }

      set acnsTest.v6 {
        type ipv6_addr
      }
    '';
    services.acns.enable = true;
    services.acns.settings.accessControl.inet."nixos-fw" = [
      "acnsTest.v4"
      "acnsTest.v6"
      "acnsTestTimeout.v4"
    ];
  };
  testScript = #python
  ''
    import json
    import ipaddress

    machine.wait_for_unit("nftables")
    machine.wait_for_unit("acns")

    def testInsertMustSucceed(family, tableName, setName, ip):
      machine.succeed(f"sudo -u acns acnsTestClient /run/acns/acns.sock {family} {tableName} {setName} {ip}")
      jsonRes = machine.succeed(f"nft -j list set {family} {tableName} {setName}")
      res = json.loads(jsonRes)["nftables"][1]["set"]["elem"]
      if ':' in ip:
        ip = ipaddress.IPv6Address(ip).compressed
      assert ip in res, f'{ip} not in {res}'

    def testInsertMustSucceedWithTimeout(family, tableName, setName, ip, timeout):
      machine.succeed(f"sudo -u acns acnsTestClient /run/acns/acns.sock {family} {tableName} {setName} {ip} {timeout}")
      jsonRes = machine.succeed(f"nft -j list set {family} {tableName} {setName}")
      res = json.loads(jsonRes)["nftables"][1]["set"]["elem"]
      if ':' in ip:
        ip = ipaddress.IPv6Address(ip).compressed
      assert any((elem["elem"]["val"] == ip and elem["elem"]["timeout"] == timeout) for elem in res), f'{ip} with ttl {timeout} not in {res}'

    def testInsertMustFail(family, tableName, setName, ip, timeout=None):
      machine.fail(f"sudo -u acns acnsTestClient /run/acns/acns.sock {family} {tableName} {setName} {ip} {' ' if timeout is None else timeout}")
      status, jsonRes = machine.execute(f"nft -j list set {family} {tableName} {setName}")
      if status == 0:
        res = json.loads(jsonRes)["nftables"][1]["set"]
        if "elem" in res:
          if ':' in ip:
            try: ip = ipaddress.IPv6Address(ip).compressed
            except: return
          assert ip not in res["elem"], f'{ip} in {res["elem"]}'

    for ip4 in [
      "42.42.42.42", "21.21.21.21",
      "0.0.0.0", "0.42.0.42", "42.0.42.0", "42.0.0.0", "0.0.0.42",
    ]:
      testInsertMustSucceed("inet", "nixos-fw", "acnsTest.v4", ip4)

    for el in [ ("42.42.42.42", 42), ("21.21.21.21", 21), ("3.3.3.3", 3) ]:
      ip, timeout = el
      testInsertMustSucceedWithTimeout("inet", "nixos-fw", "acnsTestTimeout.v4", ip, timeout)
    testInsertMustFail("inet", "nixos-fw", "acnsTestNoRight.v4", "42.42.42.42")
    testInsertMustFail("inet", "nixos-fw", "thisSetDoesNotExist", "42.42.42.42")
    testInsertMustFail("inet", "nixos-fw", "acnsTest.v4", "84.84.84.84", 42)

    for ip6 in [
      "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
      "f:ff:fff:fff0:ff0f:f00f:ffff:0",
      "f:f:f:f:f:f:f:0",
      "f:f:f:f:f:f:0:0",
      "f:0:0:0:0:0:0:0",
      "f:f::",
      "f::f",
      "f::f:a",
      "f::f:a:f",
    ]:
      testInsertMustSucceed("inet", "nixos-fw", "acnsTest.v6", ip6)

    testInsertMustFail("inet", "nixos-fw", "acnsTest.v6", "f::f:a:f::")
  '';
}

{ pkgs, projectName }:
pkgs.writeShellApplication rec {
  name = "${projectName}TestClient";
  runtimeInputs = with pkgs; [
    (luajit.withPackages (ps: with ps; [
      luasocket
    ]))
    ipv6calc
  ];
  text = ''
    function asciiToChar {
      char="$1"
      if (( char == 0 )); then
        printf "\\\0"
      else
        printf "%b" "$(printf "\\%03o" "$char")"
      fi
    }

    function helpSocketPath {
      echo "${name}SocketPath : the path to the acns socket, must be writable"
    }
    function helpNftFamily {
      echo 'nftFamily : one of [ "ip" "ip6" "inet" "arp" "bridge" "netdev" "wrong" ]'
    }

    function help {
      echo "Usage : ${name} [${name}SocketPath] [nftFamily] [nftTableName] [nftSetName] [ipv4|ipv6] [ttlInSeconds|none]"
      helpSocketPath
      helpNftFamily
    }

    if [ ''${#@} == 0 ]; then
      help; exit 0;
    fi
    if [ ''${#@} != 5 ] && [ ''${#@} != 6 ]; then
      echo "Invalid number of arguments !" >&2
      help >&2; exit 1;
    fi

    SOCKET_PATH="$1"
    NFT_FAMILY="$2"
    NFT_TABLE_NAME="$3"
    NFT_SET_NAME="$4"
    IP="$5"
    TTL=""; if [ ''${#@} == 6 ]; then TTL="$6"; fi
    
    case "$NFT_FAMILY" in
      "inet") parsedNftFamily=1;;
      "ip") parsedNftFamily=2;;
      "arp") parsedNftFamily=3;;
      "bridge") parsedNftFamily=7;;
      "ip6") parsedNftFamily=10;;
      "netdev") parsedNftFamily=14;;
      "wrong") parsedNftFamily=42;;
      *)
        echo "Invalid Nft family" >&2
        helpNftFamily >&2; exit 1;;
    esac
    parsedNftFamily="$(asciiToChar "$parsedNftFamily";asciiToChar 0)"

    splittedIp=""
    parsedIp=""
    OIFS="$IFS";IFS='.'; read -ra splittedIp <<< "$IP";IFS="$OIFS"
    if (( ''${#splittedIp[@]} == 4 )); then
      parsedIp="$(
        for o in "''${splittedIp[@]}"; do
          asciiToChar "$o"
        done
      )"
    else
      parsedIp="0x$(ipv6calc "$IP" --addr2if_inet6 | cut -f 1 -d ' ')"
    fi

    lua <(printf '
      local ackSockPath = "%s"
      local servSockPath = "%s"
      local msg = "%s%s\\0%s"
      local ip = "%s"
      if ip:sub(1,2) == "0x" then
        ip = (ip:sub(3)):gsub("..", function (cc)
          return string.char(tonumber(cc, 16))
        end)
      end
      msg = msg .. "\\0" .. ip
      local ttl = 0%s


      local Socket = require("socket")
      Socket.unix = require("socket.unix")
      local ffi = require("ffi")
      ffi.cdef [[
      typedef unsigned int mode_t;
      int unlink(const char *pathname);
      int chmod(const char *pathname, mode_t mode);
      ]]

      if (ttl > 0) then
        msg = msg .. ffi.string(ffi.new("uint32_t[1]", ttl), 4)
      end
     
      local socket = assert(Socket.unix.dgram())
      ffi.C.unlink(ackSockPath)
      assert(socket:bind(ackSockPath))
      ffi.C.chmod(ackSockPath, tonumber("620", 8))
     
      if (socket:sendto(msg, servSockPath)) then
        local ack = socket:receive()
        if ack == nil or #ack ~= 1 then
          print("failed to get ack")
          os.exit(1)
        elseif string.byte(ack, 0, 1) == 1 then
          os.exit(1)
        end
      else
        print("sendto failed")
      end
     
      socket:close()
      ffi.C.unlink(ackSockPath)
    ' \
      "$(mktemp -u /run/acns/testClient-XXXXXXX.sock)" \
      "$SOCKET_PATH" \
      "$parsedNftFamily" \
      "$NFT_TABLE_NAME" \
      "$NFT_SET_NAME" \
      "$parsedIp" \
      "$TTL" \
    )
  '';
}

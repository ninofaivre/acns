{ pkgs, projectName }:
pkgs.writeShellApplication rec {
  name = "${projectName}SimpleClient";
  runtimeInputs = with pkgs; [ socat ];
  text = ''
    function asciiToChar {
      printf "%b" "$(printf "\\%03o" "$1")"
    }

    function helpSocketPath {
      echo "${name}SocketPath : the path to the acns socket, must be writable"
    }
    function helpNftFamily {
      echo 'nftFamily : one of [ "ip" "ip6" "inet" "arp" "bridge" "netdev" "wrong" ]'
    }
    function help {
      echo "Usage : ${name} [${name}SocketPath] [nftFamily] [nftTableName] [nftSetName] [ipv4]"
      helpSocketPath
      helpNftFamily
    }

    if [ ''${#@} == 0 ]; then
      help; exit 0;
    fi
    if [ ''${#@} != 5 ]; then
      echo "Invalid number of arguments !" >&2
      help >&2; exit 1;
    fi

    SOCKET_PATH="$1"
    NFT_FAMILY="$2"
    NFT_TABLE_NAME="$3"
    NFT_SET_NAME="$4"
    IP="$5"
    
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
    parsedNftFamily="$(asciiToChar "$parsedNftFamily")"
    parsedIp="$(
      IFS='.' read -ra splittedIp <<< "$IP"
      for o in "''${splittedIp[@]}"; do
        asciiToChar "$o"
      done
    )"
    printf "%s\0%s\0%s\0%s" \
           "$parsedNftFamily" \
           "$NFT_TABLE_NAME" \
           "$NFT_SET_NAME" \
           "$parsedIp" \
    | socat - "UNIX-CLIENT:''${SOCKET_PATH}"
  '';
}

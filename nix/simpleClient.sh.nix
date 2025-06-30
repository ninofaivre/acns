{ pkgs, projectName }:
pkgs.writeShellApplication rec {
  name = "${projectName}SimpleClient";
  runtimeInputs = with pkgs; [ socat ];
  text = ''
    function asciiToChar {
      char="$1"
      if (( char == 0 )); then
        printf "\\\0"
        return
      fi
      printf "%b" "$(printf "\\%03o" "$char")"
    }

    function helpSocketPath {
      echo "${name}SocketPath : the path to the acns socket, must be writable"
    }
    function helpNftFamily {
      echo 'nftFamily : one of [ "ip" "ip6" "inet" "arp" "bridge" "netdev" "wrong" ]'
    }

    function wrongIpV6Number {
      reason="$1"
      echo "wrong ipv6 number :" "$reason" >&2
      help >&2
      exit 2
    }

    function help {
      echo "Usage : ${name} [${name}SocketPath] [nftFamily] [nftTableName] [nftSetName] [ipv4|ipv6]"
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

    splittedIp=""
    parsedIp=""
    IFS='.'; read -ra splittedIp <<< "$IP"
    if (( ''${#splittedIp[@]} == 4 )); then
      parsedIp="$(
        for o in "''${splittedIp[@]}"; do
          asciiToChar "$o"
        done
      )"
    else
      IFS=':'; read -ra splittedIp <<< "$IP"
      if (( ''${#splittedIp[@]} > 8 )); then
        wrongIpV6Number "more than 8 groups of for 4 hex digits"
      fi
      if ! parsedIp="$(
        doubleColonEncountered=false
        for hexNumber in "''${splittedIp[@]}"; do
          if [ ''${#hexNumber} == 0 ]; then
            if [ "$doubleColonEncountered" == true ]; then
              wrongIpV6Number "you can have two colon in a raw only once in an ipv6"
            fi
            doubleColonEncountered=true
            printf "\\\0%.0s" "$(eval "echo {1..$((2 * (8 - ''${#splittedIp[@]})))}")"
            continue ;
          fi
          if (( ''${#hexNumber} > 4 )); then
            wrongIpV6Number "more than 4 chars to the following hex number : ''${hexNumber}"
          elif (( ''${#hexNumber} < 4 )); then
            hexNumber="$(printf '0%.0s' "$(eval "echo {1..$((4 - ''${#hexNumber}))}")")''${hexNumber}"
          fi

          if ! firstAsciiChar="$((16#''${hexNumber:0:2}))"; then exit $?; fi
          asciiToChar "$firstAsciiChar"
          if ! secondAsciiChar="$((16#''${hexNumber:2:2}))"; then exit $?; fi
          asciiToChar "$secondAsciiChar"
        done
      )"; then exit $?;fi
    fi
    printf "%s\0%s\0%s\0%b" \
           "$parsedNftFamily" \
           "$NFT_TABLE_NAME" \
           "$NFT_SET_NAME" \
           "$parsedIp" \
    | socat - "UNIX-CLIENT:''${SOCKET_PATH}"
  '';
}

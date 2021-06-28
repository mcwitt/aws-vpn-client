#!/usr/bin/env bash

set -e

# replace with your hostname
VPN_HOST="$AWS_VPN_CLIENT_VPN_HOST"
# path to the patched openvpn
OVPN_BIN=openvpn
# path to the configuration file
OVPN_CONF="$AWS_VPN_CLIENT_OVPN_CONF"
PORT="$AWS_VPN_CLIENT_PORT"
OVPN_SVC="$AWS_VPN_CLIENT_OVPN_SVC"
PROTO=udp

SAML_RESPONSE_FILE=/etc/openvpn/saml-response.txt

wait_file() {
  local file="$1"; shift
  local wait_seconds="${1:-10}"; shift # 10 seconds as default timeout
  until test $((wait_seconds--)) -eq 0 -o -f "$file" ; do sleep 1; done
  ((++wait_seconds))
}

# create random hostname prefix for the vpn gw
RAND=$(openssl rand -hex 12)

# resolv manually hostname to IP, as we have to keep persistent ip address
SRV=$(dig a +short "${RAND}.${VPN_HOST}"|head -n1)

echo "Getting SAML redirect URL from the AUTH_FAILED response (host: ${SRV}:${PORT})"
OVPN_OUT=$($OVPN_BIN --config "${OVPN_CONF}" --verb 3 \
     --proto "$PROTO" --remote "${SRV}" "${PORT}" \
     --auth-user-pass <( printf "%s\n%s\n" "N/A" "ACS::35001" ) \
    2>&1 | grep AUTH_FAILED,CRV1)

echo "Opening browser and wait for the response file..."
URL=$(echo "$OVPN_OUT" | grep -Eo 'https://.+')

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     xdg-open "$URL";;
    Darwin*)    open "$URL";;
    *)          echo "Could not determine 'open' command for this OS"; exit 1;;
esac

wait_file "$SAML_RESPONSE_FILE" 30 || {
  echo "SAML Authentication time out"
  exit 1
}

# get SID from the reply
VPN_SID=$(echo "$OVPN_OUT" | awk -F : '{print $7}')

AUTH_FILE="$(dirname "$OVPN_CONF")/auth.txt"

echo "Using sudo to update credentials and restart service. Enter password if requested."
sudo \
    VPN_SID="$VPN_SID" \
    SAML_RESPONSE_FILE="$SAML_RESPONSE_FILE" \
    AUTH_FILE="$AUTH_FILE" \
    OVPN_SVC="$OVPN_SVC" \
    /usr/bin/env bash <<'EOF'
printf "%s\n%s\n" "N/A" "CRV1::${VPN_SID}::$(cat "$SAML_RESPONSE_FILE")" > "$AUTH_FILE"
rm -f "$SAML_RESPONSE_FILE"
echo "OpenVPN credentials written to ${AUTH_FILE}. Restarting ${OVPN_SVC}..."
systemctl restart ${OVPN_SVC}
EOF

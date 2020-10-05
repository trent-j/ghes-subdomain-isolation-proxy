#!/bin/bash

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

ROOT_CA="${DIR}/ghes-root-ca.pem"
ROOT_CA_KEY="${DIR}/ghes-root-ca.key.pem"

GHES_KEY="${DIR}/ghes.key"
GHES_CSR="${DIR}/ghes.csr"
GHES_CRT="${DIR}/ghes.crt"

SSL_CONFIG_TEMPLATE="${DIR}/openssl.cnf.template"
SSL_CONFIG="${DIR}/openssl.cnf"

HOSTS_FILE="/etc/hosts"

LOCALHOST_ALIAS='127.0.0.2'

PROXY_NAME='ghes-proxy'

generate_and_trust_root_ca () {

    # Generate root CA key
    openssl genrsa -out "$ROOT_CA_KEY" 2048

    # Sign root CA
    openssl req \
        -x509 \
        -new \
        -nodes \
        -key "$ROOT_CA_KEY" \
        -days 1024 \
        -out "$ROOT_CA" \
        -subj "/C=US/ST=Texas/L=Dallas/O=GitHub Signing Authority/CN=GitHub Signing Authority"

    # Trust root CA (all certificates signed with this CA with automatically be trusted)
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ROOT_CA"
}

generate_ssl_config () {
    cp "$SSL_CONFIG_TEMPLATE" "$SSL_CONFIG"
    printf 'DNS.1 = *.%s\nDNS.2 = %s\n' "$HOST" "$HOST" >> "$SSL_CONFIG"
}

generate_ghes_cert () {

    # Generate ghes key
    openssl genrsa -out "$GHES_KEY" 2048

    # Generate certificate signing request
    openssl req \
        -new \
        -key "$GHES_KEY" \
        -out "$GHES_CSR" \
        -config "$SSL_CONFIG"

    # Generate and sign ghes certificate
    openssl x509 \
        -sha256 \
        -req \
        -in "$GHES_CSR" \
        -CA "$ROOT_CA" \
        -CAkey "$ROOT_CA_KEY" \
        -CAcreateserial \
        -out "$GHES_CRT" \
        -days 500 \
        -extensions v3_req \
        -extfile "$SSL_CONFIG"
}

generate_certs () {
    generate_and_trust_root_ca
    generate_ssl_config
    generate_ghes_cert
}

setup_port_forwarding () {

    # Create localhost alias
    sudo ifconfig lo0 alias 127.0.0.2

    # Forward port specified (defaults to 9000) to port 443
    echo "rdr pass inet proto tcp from any to any port 443 -> $LOCALHOST_ALIAS port $PORT" | sudo pfctl -ef - &> /dev/null || return 0
}

remove_old_subdomain_host () {
    sudo sed -i.bak -e "/^$LOCALHOST_ALIAS .*\.service\.bpdev-us-east-1\.github\.net/d" "$HOSTS_FILE"
    sudo rm -f "$HOSTS_FILE.bak"
}

add_subdomain_hosts () {

    SUBDOMAINS=(
        'docker'
        'maven'
        'npm'
        'rubygems'
        'nuget'
        'assets'
        'avatars'
        'codeload'
        'gist'
        'media'
        'pages'
        'raw'
        'render'
        'reply'
        'uploads'
    )

    for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
        echo "$LOCALHOST_ALIAS $SUBDOMAIN.$HOST" | sudo tee -a "$HOSTS_FILE"
    done
}

setup_subdomain_hosts () {
    remove_old_subdomain_host
    add_subdomain_hosts
}

start_proxy () {

    # Stop old proxy if running
    if docker ps -a --format '{{.Names}}' | grep -q "$PROXY_NAME"; then
        docker rm -f "$PROXY_NAME"
    fi

    # Start proxy with new certs and host
    docker run \
        -d \
        --rm \
        --name "$PROXY_NAME" \
        -p "$PORT:9000" \
        -v "$DIR:/tmp/certs:ro" \
        -e BP_DEV_URL="https://${HOST}" \
        -e GHES_CERT='/tmp/certs/ghes.crt' \
        -e GHES_KEY='/tmp/certs/ghes.key' \
        ghcr.io/trent-j/reverse-proxy:v2
}

cleanup () {
    rm -f "$ROOT_CA" "$ROOT_CA_KEY" "$GHES_KEY" "$GHES_CSR" "$GHES_CRT" "$SSL_CONFIG" "$DIR/ghes-root-ca.srl"
}

while (( "$#" )); do
    case "$1" in
        --host ) HOST="$2" && shift 2;;
        --port ) PORT="$2" && shift 2;;
    esac
done

[[ -z $HOST ]] && echo "host is required" && exit 1

PORT="${PORT:-9000}"

cleanup
generate_certs
setup_port_forwarding
setup_subdomain_hosts
start_proxy

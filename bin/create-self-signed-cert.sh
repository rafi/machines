#!/usr/bin/env bash
# Create self-signed certificate with password.
# Credits: https://github.com/rapiz1/rathole/blob/main/examples/tls/create_self_signed_cert.sh
set -eu

# CN: CommonName
# OU: OrganizationalUnit
# O: Organization
# L: Locality
# S: StateOrProvinceName
# C: CountryName

PASSWORD="$1"
test -z "$PASSWORD" && echo "Password is required" && exit 1

COMMON_NAME="MyCA"
ORGANIZATION_UNIT="Someone"
ORGANIZATION="Someone"
LOCALITY="Universe"
STATE_OR_PROVINCE="Earth"
COUNTRY_NAME="US"

# Create common authority (CA)
openssl req -x509 \
	-sha256 -days 356 \
	-nodes \
	-newkey rsa:2048 \
	-subj "/CN=$COMMON_NAME/C=$COUNTRY_NAME/L=$LOCALITY" \
	-keyout rootCA.key -out rootCA.crt

# Create server private key
openssl genrsa -out server.key 2048

# Create certificate signing request (CSR)
cat > csr.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C = $COUNTRY_NAME
ST = $STATE_OR_PROVINCE
L = $LOCALITY
O = $ORGANIZATION
OU = $ORGANIZATION_UNIT
CN = localhost

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
EOF

openssl req -new -key server.key -out server.csr -config csr.conf

# Create Server certificate
cat > cert.conf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
EOF

openssl x509 -req \
	-in server.csr \
	-CA rootCA.crt -CAkey rootCA.key \
	-out server.crt \
	-days 365 \
	-sha256 -extfile cert.conf

# create pkcs12
openssl pkcs12 -export \
	-out identity.pfx -inkey server.key -in server.crt -certfile rootCA.crt \
	-passout "pass:$PASSWORD" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

# Clean up
rm server.csr csr.conf cert.conf

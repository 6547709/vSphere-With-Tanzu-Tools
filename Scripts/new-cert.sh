#!/bin/bash

# Copyright (c) 2020 VMware, Inc. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

USAGE="
usage: ${0} [FLAGS] COMMON_NAME [OUT_DIR]
  Creates a new certificate and writes its public and private keys as
  two PEM-encoded files, server.crt and server.key.
COMMON_NAME
  The certificate's common name. This is a required argument.
OUT_DIR
  An optional argument that specifies the directory to which to write
  the public and private keys. If omitted, they files are written to
  the working directory.
FLAGS
  -h    show this help and exit
  -1    the public key of the CA used to sign the new certificate
  -2    the private key of the CA used to sign the new certificate
  -3    a comma-separated string of IP SANs
  -4    a comma-separated string of DNS SANs
  -c    country (defaults to US)
  -s    state or province (defaults to CA)
  -l    locality (defaults to Palo Alto)
  -o    organization (defaults to VMware)
  -u    organizational unit (defaults to CAPV)
  -b    bit size (defaults to 2048)
  -d    days until expiry (defaults to 3650)
  -k    key usage (defaults to digitalSignature, keyEncipherment)
  -e    extended key usage (defaults to clientAuth, serverAuth)
  -f    file name prefix (defaults to server)
  -n    skip generating a certificate and key if one already exists.
"

function error() {
  local exit_code="${?}"
  echo "${@}" 1>&2
  return "${exit_code}"
}

function fatal() {
  error "${@}" || exit 1
}

# Start of main script
while getopts ":hvn1:2:3:4:c:s:l:o:u:b:d:k:e:f:" opt; do
  case ${opt} in
    h)
      error "${USAGE}" && exit 1
      ;;
    1)
      TLS_CA_CRT="${OPTARG}"
      ;;
    2)
      TLS_CA_KEY="${OPTARG}"
      ;;
    3)
      TLS_IP_SANS="${OPTARG}"
      ;;
    4)
      TLS_DNS_SANS="${OPTARG}"
      ;;
    c)
      TLS_COUNTRY_NAME="${OPTARG}"
      ;;
    s)
      TLS_STATE_OR_PROVINCE_NAME="${OPTARG}"
      ;;
    l)
      TLS_LOCALITY_NAME="${OPTARG}"
      ;;
    o)
      TLS_ORG_NAME="${OPTARG}"
      ;;
    u)
      TLS_OU_NAME="${OPTARG}"
      ;;
    b)
      TLS_DEFAULT_BITS="${OPTARG}"
      ;;
    d)
      TLS_DEFAULT_DAYS="${OPTARG}"
      ;;
    k)
      TLS_KEY_USAGE="${OPTARG}"
      ;;
    e)
      TLS_EXT_KEY_USAGE="${OPTARG}"
      ;;
    f)
      TLS_FILE_PREFIX="${OPTARG}"
      ;;
    n)
      NO_OVERWRITE=1
      ;;
    v)
      VERBOSE=1
      set -x
      ;;
    \?)
      error "invalid option: -${OPTARG} ${USAGE}" && exit 1
      ;;
    :)
      error "option -${OPTARG} requires an argument" && exit 1
      ;;
  esac
done
shift $((OPTIND-1))

# Verbose mode
VERBOSE="${VERBOSE-}"
NO_OVERWRITE="${NO_OVERWRITE-}"

# The strength of the generated certificate
TLS_DEFAULT_BITS=${TLS_DEFAULT_BITS:-2048}

# The number of days until the certificate expires. The default
# value is 10 years.
TLS_DEFAULT_DAYS=${TLS_DEFAULT_DAYS:-3650}

# The components that make up the certificate's distinguished name.
TLS_COUNTRY_NAME=${TLS_COUNTRY_NAME:-US}
TLS_STATE_OR_PROVINCE_NAME=${TLS_STATE_OR_PROVINCE_NAME:-California}
TLS_LOCALITY_NAME=${TLS_LOCALITY_NAME:-Palo Alto}
TLS_ORG_NAME=${TLS_ORG_NAME:-VMware}
TLS_OU_NAME=${TLS_OU_NAME:-CAPV}

# The certificate's key usage.
TLS_KEY_USAGE=${TLS_KEY_USAGE:-digitalSignature, keyEncipherment}

# The certificate's extended key usage string.
TLS_EXT_KEY_USAGE=${TLS_EXT_KEY_USAGE:-clientAuth, serverAuth}

# The file name prefix for the public and private keys.
TLS_FILE_PREFIX=${TLS_FILE_PREFIX:-server}

# The certificate's common name.
[ "${#}" -ge "1" ] || fatal "COMMON_NAME is required ${USAGE}"
TLS_COMMON_NAME="${1}"

# The signing CA.
[ -e "${TLS_CA_CRT-}" ] || fatal "the public key of the CA must be specified with -1 ${USAGE}"
[ -e "${TLS_CA_KEY-}" ] || fatal "the private key of the CA must be specified with -2 ${USAGE}"

# The directory to which to write the public and private keys.
{ [ "${#}" -gt "1" ] && OUT_DIR="${2}"; } || OUT_DIR="$(pwd)"
mkdir -p "${OUT_DIR}"

if { [ -f "${OUT_DIR}/${TLS_FILE_PREFIX}.crt" ] || [ -f "${OUT_DIR}/${TLS_FILE_PREFIX}.key" ]; } && [ $NO_OVERWRITE ]; then
  echo "Existing ${TLS_FILE_PREFIX}.crt or ${TLS_FILE_PREFIX}.key "\
  "exists in ${OUT_DIR}. Skipping cert generation."
  exit 0
fi

# Make a temporary directory and switch to it.
OLD_DIR="$(pwd)"
pushd "$(mktemp -d)"
TLS_TMP_DIR="$(pwd)"

# Returns the absolute path of the provided argument.
abspath() {
  { [ "$(printf %.1s "${1}")" = "/" ] && echo "${1}"; } || echo "${OLD_DIR}/${1}"
}

# Write the SSL config file to disk.
cat >ssl.conf <<EOF
[ req ]
default_bits           = ${TLS_DEFAULT_BITS}
default_days           = ${TLS_DEFAULT_DAYS}
encrypt_key            = no
default_md             = sha1
prompt                 = no
utf8                   = yes
distinguished_name     = dn
req_extensions         = ext
x509_extensions        = ext
[ dn ]
countryName            = ${TLS_COUNTRY_NAME}
stateOrProvinceName    = ${TLS_STATE_OR_PROVINCE_NAME}
localityName           = ${TLS_LOCALITY_NAME}
organizationName       = ${TLS_ORG_NAME}
organizationalUnitName = ${TLS_OU_NAME}
commonName             = ${TLS_COMMON_NAME}
[ ext ]
basicConstraints       = CA:FALSE
keyUsage               = ${TLS_KEY_USAGE}
extendedKeyUsage       = ${TLS_EXT_KEY_USAGE}
subjectKeyIdentifier   = hash
EOF

if [ -n "${TLS_IP_SANS-}" ] || [ -n "${TLS_DNS_SANS-}" ]; then
  cat >> ssl.conf <<EOF
subjectAltName         = @sans
# DNS.1     repeats the certificate's CN. Some clients have been known
#           to ignore the subject if SANs are set.
# DNS.2-n-1 are additional DNS SANs
#
# IP.1-n-1  are additional IP SANs
[ sans ]
DNS.1                  = ${TLS_COMMON_NAME}
EOF
  # Append any DNS SANs to the SSL config file.
  i=2 && for j in $(echo "${TLS_DNS_SANS-}" | tr ',' ' '); do
    echo "DNS.${i}                  = ${j}" >>ssl.conf && i="$(( i+1 ))"
  done

  # Append any IP SANs to the SSL config file.
  i=1 && for j in $(echo "${TLS_IP_SANS-}" | tr ',' ' '); do
    echo "IP.${i}                   = ${j}" >>ssl.conf && i="$(( i+1 ))"
  done
fi

[ -z "${VERBOSE}" ] || cat ssl.conf

# Generate a private key file.
openssl genrsa -out "${TLS_FILE_PREFIX}.key" "${TLS_DEFAULT_BITS}"

# Generate a certificate CSR.
openssl req -config ssl.conf \
            -new \
            -key "${TLS_FILE_PREFIX}.key" \
            -days "${TLS_DEFAULT_DAYS}" \
            -out "${TLS_FILE_PREFIX}.csr"

# Sign the CSR with the provided CA.
openssl x509 -extfile ssl.conf \
             -extensions ext \
             -days "${TLS_DEFAULT_DAYS}" \
             -req \
             -in "${TLS_FILE_PREFIX}.csr" \
             -CA "$(abspath "${TLS_CA_CRT}")" \
             -CAkey "$(abspath "${TLS_CA_KEY}")" \
             -CAcreateserial \
             -out "${TLS_FILE_PREFIX}.crt"


if [[ ! -f "${TLS_FILE_PREFIX}.crt" || ! -f "${TLS_FILE_PREFIX}.key" ]]; then
  echo "failed to output certificate and key"
  exit 1
fi

# Copy the files to OUT_DIR
cp -f "${TLS_FILE_PREFIX}.crt" "${TLS_FILE_PREFIX}.key" "$(abspath "${OUT_DIR}")"

# Print the certificate's information if requested.
[ -z "${VERBOSE}" ] || { echo && openssl x509 -noout -text <"${TLS_FILE_PREFIX}.crt"; }

# Return to the original directory and cleanup the temporary TLS dir.
popd
rm -fr "${TLS_TMP_DIR}"

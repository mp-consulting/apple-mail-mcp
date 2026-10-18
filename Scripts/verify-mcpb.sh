#!/bin/bash
# Verifies the signature of a signed Claude extension (.mcpb) with OpenSSL.
#
# `mcpb verify` (2.1.x) cannot do it: node-forge has no PKCS#7 verification ("not yet implemented"),
# so it reports every file as unsigned. A signed .mcpb is the zip, then MCPB_SIG_V1, a little-endian
# UInt32 length, the DER PKCS#7 signature and MCPB_SIG_END.
#
# Usage: Scripts/verify-mcpb.sh <file.mcpb> <CA file (PEM)> [expected signer common name]
set -euo pipefail

MCPB="$1"
CA_FILE="$2"
EXPECTED_SIGNER="${3:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$MCPB" "$WORK" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
work = sys.argv[2]
footer = data.rfind(b"MCPB_SIG_END")
header = data.rfind(b"MCPB_SIG_V1", 0, footer)
if footer < 0 or header < 0:
    sys.exit("not signed: no MCPB signature block")
offset = header + len(b"MCPB_SIG_V1")
(length,) = struct.unpack_from("<I", data, offset)
open(f"{work}/content.zip", "wb").write(data[:header])
open(f"{work}/signature.der", "wb").write(data[offset + 4 : offset + 4 + length])
PY

# Checks the signature, the content digest and the chain up to the CA file. Developer ID certificates
# carry an Apple-specific critical extension OpenSSL does not know, hence -ignore_critical; the signer
# name is pinned below.
openssl cms -verify -binary -inform DER -in "$WORK/signature.der" -content "$WORK/content.zip" \
    -CAfile "$CA_FILE" -purpose any -ignore_critical -certsout "$WORK/certs.pem" -out /dev/null

SIGNER="$(openssl x509 -in "$WORK/certs.pem" -noout -subject -nameopt multiline \
    | sed -n 's/^ *commonName *= *//p')"
echo "Signed by: $SIGNER"
if [ -n "$EXPECTED_SIGNER" ] && [ "$SIGNER" != "$EXPECTED_SIGNER" ]; then
    echo "error: expected signer \"$EXPECTED_SIGNER\"" >&2
    exit 1
fi

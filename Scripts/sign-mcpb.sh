#!/bin/bash
# Signs a Claude extension (.mcpb) so that strict zip readers, Claude's among them, can still open it.
#
# `mcpb sign` (2.1.x) appends the signature block after the zip's end-of-central-directory record but
# leaves the record's comment length at 0. Claude then refuses the file: "Invalid comment length.
# Expected: 4203. Found: 0." The comment length has to cover the signature block, and it has to be set
# before signing, because the signature covers everything before the block. So: sign a copy to learn
# the block's size (fixed for a given certificate and key), write that size into the comment length,
# sign the real file, and check that the size did not change.
#
# Usage: Scripts/sign-mcpb.sh <file.mcpb> <cert.pem> <key.pem> [intermediate.pem ...]
set -euo pipefail

MCPB="$1"
CERT="$2"
KEY="$3"
shift 3
INTERMEDIATES=("$@")

MCPB_CLI=(npx --yes @anthropic-ai/mcpb@2.1.2)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sign() {
    if [ ${#INTERMEDIATES[@]} -gt 0 ]; then
        "${MCPB_CLI[@]}" sign "$1" --cert "$CERT" --key "$KEY" --intermediate "${INTERMEDIATES[@]}"
    else
        "${MCPB_CLI[@]}" sign "$1" --cert "$CERT" --key "$KEY"
    fi
}

# Sets the comment length of the zip's end record to the given number of bytes, or checks that the
# signed file's comment length matches the bytes after the end record.
eocd() {
    python3 -I - "$@" <<'PY'
import struct, sys
mode, path = sys.argv[1], sys.argv[2]
data = bytearray(open(path, "rb").read())
end = data.rfind(b"PK\x05\x06")
if end < 0:
    sys.exit(f"{path}: no zip end-of-central-directory record")
(current,) = struct.unpack_from("<H", data, end + 20)
if mode == "set":
    if current != 0:
        sys.exit(f"{path}: the zip already has a comment ({current} bytes)")
    struct.pack_into("<H", data, end + 20, int(sys.argv[3]))
    open(path, "wb").write(data)
elif mode == "check":
    trailing = len(data) - end - 22
    if current != trailing:
        sys.exit(f"{path}: zip comment length is {current}, but {trailing} bytes follow the end record")
PY
}

UNSIGNED_SIZE=$(stat -f %z "$MCPB")
cp "$MCPB" "$WORK/probe.mcpb"
sign "$WORK/probe.mcpb"
BLOCK=$(( $(stat -f %z "$WORK/probe.mcpb") - UNSIGNED_SIZE ))

eocd set "$MCPB" "$BLOCK"
sign "$MCPB"
eocd check "$MCPB"
echo "Signed $(basename "$MCPB") (signature block: $BLOCK bytes)"

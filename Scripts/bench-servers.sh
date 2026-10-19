#!/bin/bash
# Prepares the other Apple Mail MCP servers for `mail-bench compare`, then runs it.
# Run from a terminal that has Full Disk Access: the indexes of imdinu and parasxos read Mail's files.
#
#   Scripts/bench-servers.sh            fetch, index, then benchmark into Benchmarks/compare-mcp-servers.md
#                                       (servers reading Mail's files) and compare-servers.md (AppleScript ones)
#   Scripts/bench-servers.sh --prepare  fetch and index only
#
# Versions are pinned; release files are checked against the SHA-256 published in the MCP registry.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$HOME/Library/Caches/AppleMailMCP/bench-servers"
build="$HOME/Library/Caches/apple-mail-mcp-build"
mkdir -p "$dir"

if ! ls "$HOME/Library/Mail" >/dev/null 2>&1; then
  echo "This terminal cannot read ~/Library/Mail. Give it Full Disk Access (System Settings > Privacy & Security)," >&2
  echo "then quit and reopen it. Terminals inside other apps (Claude, VS Code) need that app to have the access." >&2
  exit 1
fi

fetch() {  # url sha256 destination
  if [ ! -f "$3" ] || ! echo "$2  $3" | shasum -a 256 -c --status; then
    curl -fsSL -o "$3.download" "$1"
    echo "$2  $3.download" | shasum -a 256 -c --status || { echo "checksum mismatch: $1" >&2; exit 1; }
    mv "$3.download" "$3"
  fi
}

fetch https://github.com/kiki830621/che-apple-mail-mcp/releases/download/v2.0.1/CheAppleMailMCP \
  a532b80e0d0390dc755d0b64a319398df5806f399f982b427fe56d527726513a "$dir/CheAppleMailMCP"
chmod +x "$dir/CheAppleMailMCP"
fetch https://github.com/ipsupport-llc/apple-mail-mcp/releases/download/v1.6.1/apple-mail-mcp.mcpb \
  651ba036870674fb93ca58bf1d209686af32ff40897038cab3633dbf0810ad11 "$dir/ipsupport-llc.mcpb"
rm -rf "$dir/ipsupport-llc" && unzip -q "$dir/ipsupport-llc.mcpb" -d "$dir/ipsupport-llc"

# Package downloads happen now, not inside the first timed call.
for package in @jakobf1/apple-mail-mcp@0.6.2 @jdot6/apple-mail-mcp@0.1.0 @mgcrea/mcp-apple-mail@1.28.0; do
  npm exec -y --package="$package" -- true >/dev/null 2>&1 || true
done

# A failed index is reported, not fatal: that server's searches then show what users without one get.
echo "Building the imdinu index…"
uvx apple-mail-mcp@0.5.0 index || echo "warning: the imdinu index failed (exit $?)" >&2
echo "Building the parasxos index…"
uvx --from apple-mailbox-mcp@1.8.0 apple-mailbox-mcp fts --build || echo "warning: the parasxos index failed (exit $?)" >&2

[ "${1:-}" = "--prepare" ] && exit 0

swift build -c release --scratch-path "$build" --product apple-mail-mcp
swift build -c release --scratch-path "$build" --product mail-bench
# The servers that read Mail's files, in turns, 25 runs each; our server gets a throwaway index (no Keychain prompt).
"$build/release/mail-bench" compare --server "$build/release/apple-mail-mcp" --servers imdinu,mgcrea,parasxos \
  --runs 25 --other-runs 25 --fresh-index --out Benchmarks/compare-mcp-servers.md
# The ones that drive Mail with AppleScript, one run each (they take seconds per question and keep Mail busy).
"$build/release/mail-bench" compare --server "$build/release/apple-mail-mcp" \
  --servers ipsupport,jakobfigur,jayvee6,kiki830621,python --fresh-index --out Benchmarks/compare-servers.md

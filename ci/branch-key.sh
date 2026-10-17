#!/bin/bash
# branch-key.sh <owner/repo> <ref> -- file-name-safe key for the poller state files
# (last-tested.<key>, last-eessi.<key>, seen.<key>). Upstream branches keep their plain
# name (1.9-dev, main) so existing state stays valid; fork branches get the owner prefixed.
repo="$1"; ref="$2"
if [ "$repo" = brainmatt/mattx ]; then k="$ref"; else k="${repo%%/*}_$ref"; fi
echo "${k//\//_}"

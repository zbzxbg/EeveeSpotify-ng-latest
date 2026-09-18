#!/bin/bash

# Test Spotify internal APIs for track metadata
# Track ID: 4A2eDiBGdWZMiH1uWd0p1Y (Never Gonna Give You Up - Rick Astley)

TRACK_ID="4A2eDiBGdWZMiH1uWd0p1Y"

echo "Testing Spotify Internal APIs for track metadata..."
echo "Track ID: $TRACK_ID"
echo ""

# API 1: Metadata v4
echo "=== API 1: metadata/4/track ==="
curl -s "https://spclient.wg.spotify.com/metadata/4/track/$TRACK_ID" | head -c 500
echo -e "\n"

# API 2: Metadata v3
echo "=== API 2: metadata/3/track ==="
curl -s "https://api.spotify.com/v1/tracks/$TRACK_ID" | jq -r '.name, .artists[0].name' 2>/dev/null || echo "Failed or needs auth"
echo ""

# API 3: Extended metadata
echo "=== API 3: extended-metadata ==="
curl -s "https://spclient.wg.spotify.com/extended-metadata/v0/track/$TRACK_ID" | head -c 500
echo -e "\n"

# API 4: Track metadata service
echo "=== API 4: track-playback ==="
curl -s "https://guc3-spclient.spotify.com/track-playback/v1/metadata/$TRACK_ID" | head -c 500
echo -e "\n"

# API 5: Color lyrics endpoint (we know this works)
echo "=== API 5: color-lyrics (known working) ==="
curl -s "https://guc3-spclient.spotify.com/color-lyrics/v2/track/$TRACK_ID" | jq -r '.lyrics.lines[0].words' 2>/dev/null | head -c 200
echo -e "\n"

# API 6: Context resolver
echo "=== API 6: context-resolver ==="
curl -s "https://spclient.wg.spotify.com/context-resolve/v1/spotify:track:$TRACK_ID" | head -c 500
echo -e "\n"

echo "=== Done ==="

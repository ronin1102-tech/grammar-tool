#!/bin/sh
# Generate a ~500-word payload with known grammar errors for the active-load benchmark.
# Repeats a 10-word sentence with 2 embedded errors ~50x = ~500 words.
python3 - <<'EOF'
sent = "The manager reviewed the report carefully before the meeting yesterday. "
err  = "Their was a obvious mistake in the summary section of it. "
text = (sent + err) * 50
open("/tmp/lwa-payload-500.txt", "w").write(text)
print("words:", len(text.split()))
EOF

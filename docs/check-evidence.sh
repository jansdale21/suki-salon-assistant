#!/usr/bin/env bash
# Lists every placeholder still on the website. Run before submitting: the output should be empty.
cd "$(dirname "$0")" || exit 1
grep -n -o -E 'data-id="[^"]+"|class="todo"|class="draft"|EVIDENCE NEEDED|VIDEO_ID' *.html | sort | uniq -c | sort -rn
echo "---"; echo "Remaining markers: $(grep -c -E 'evidence-needed|class="todo"|class="draft"' *.html | awk -F: '{s+=$2} END {print s}')"

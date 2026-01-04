#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

if [ -z "$2" ]; then
    HASH_FILENAME="$(basename "$1").sha256"
else
    HASH_FILENAME="$2"
fi

hashdeep -l -c sha256 -r "$1" | awk -F, '!/^#/ {print $2 "  " $3}' | tee "$HASH_FILENAME"
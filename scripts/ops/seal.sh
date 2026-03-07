#!/usr/bin/env bash
set -e

# Secret Sealer Macro

UNSEALED=$1
SEALED=$2

if [[ -z "$UNSEALED" ]]; then
    echo "Usage: $0 <unsealed-file> [sealed-file]"
    exit 1
fi

# check if unsealed file exists
if [[ ! -f "$UNSEALED" ]]; then
    echo "Error: file not found: $UNSEALED"
    exit 1
fi

DIRNAME=$(dirname "$UNSEALED")
BASENAME=$(basename "$UNSEALED")

if [[ ! "$BASENAME" =~ ^unsealed- ]]; then
    echo "Error: file name must start with 'unsealed-'."
    exit 1
fi

# remove prefix 'unsealed-'
CORE_NAME=${BASENAME#unsealed-}

if [[ -z "$CORE_NAME" ]]; then
    echo "Error: file name should be in the format 'unsealed-<name>'. Example: 'unsealed-secret.yaml'"
    exit 1
fi

# default sealed filename
if [[ -z "$SEALED" ]]; then
    SEALED="$DIRNAME/sealed-$CORE_NAME"
fi

echo "Processing: $BASENAME -> sealed-$CORE_NAME"

kubeseal --controller-name=sealed-secrets \
         --controller-namespace=bootstrap \
         --format yaml \
         < "$UNSEALED" \
         > "$SEALED"

if [[ $? -eq 0 ]]; then
    echo "Successfully sealed."  
else
    echo "Error: kubeseal execution failed."
    exit 1
fi
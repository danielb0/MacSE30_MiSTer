#!/usr/bin/env bash
# Disassemble Bolle's six SE/30 PAL JEDECs with the schematic's pin names.
# The JEDECs are read-only (CC-BY-NC-SA) and live outside the repo.
#   JEDS=/path/to/bolle-repro  (default: the Docs folder)
set -u
cd "$(dirname "$0")"
JEDS=${JEDS:-/c/temp/Mac/SE30/Docs/bolle-repro}
for p in UG7 UG6 UE7 UE6 UI6 UH7; do
  echo "=================================================================== $p"
  python ../jedec_dis.py dis "$JEDS/${p}_16v8.JED" --pins "@$p.pins"
done

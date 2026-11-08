#!/usr/bin/env bash
# night59's helper: ./run_<sweep>.sh with the rest as its arguments
s=$1; shift; exec "./run_$s.sh" "$@"

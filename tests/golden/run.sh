#!/bin/bash

# Strip the output of any color escape sequences.
../../zig-out/bin/zigcount "$@" 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g'

exit_code=${PIPESTATUS[0]}

exit $exit_code

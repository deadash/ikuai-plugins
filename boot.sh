#!/bin/bash

execute_scripts()
{
    local BOOT_PATH="/etc/mnt/.boot"
    test -d "$BOOT_PATH/scripts" && \
    find "$BOOT_PATH/scripts" -maxdepth 1 -type f -name "[0-9][0-9]*" -print0 | \
    sort -z -n | \
    while IFS= read -r -d '' script; do
        test -x "$script" && "$script"
    done
    return
}

execute_scripts
#!/bin/bash

. /etc/mnt/.boot/lib/common.sh

is_enabled "sshd" || exit 0

# 开启sshd
sed -i 's|/etc/setup/rc|/bin/bash|' /etc/passwd
#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

# use the tsc clocksource by default
# https://repost.aws/knowledge-center/manage-ec2-linux-clock-source
sudo sed -i.bak \
    "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\\)\"/\\1 clocksource=tsc tsc=reliable\"/" \
    "/etc/default/grub"
sudo update-grub

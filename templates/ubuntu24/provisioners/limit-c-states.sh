#!/usr/bin/env bash
set -o pipefail
set -o nounset
set -o errexit

if [ "$ENABLE_EFA" != "true" ]; then
  exit 0
fi

echo "Limiting deeper C-states"
sudo sed -i.bak \
    "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\\)\"/\\1 intel_idle.max_cstate=1 processor.max_cstate=1\"/" \
    "/etc/default/grub"
sudo update-grub

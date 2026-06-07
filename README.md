# Soter Key Fixer

KernelSU module that repairs SOTER Key issues on OnePlus Snapdragon devices with unlocked bootloader.

## Credits
This module is a fork of the original work by **酷安@小黄泊**:
- Original repo: https://github.com/xiaohuangbo/SoterFixer
- License: GPL-2.0

## What's different in this fork
The original module uses a simple repair loop that runs at boot but is unreliable due to TEE initialization timing. This fork moves the repair logic to `boot-completed.sh` with:
- 90 second delay after boot to allow TEE stabilization
- 25 repair attempts at 10 second intervals (~4 minutes total)
- Execution log at `/data/local/tmp/soterfix.log`

## Compatibility
- KernelSU / KernelSU Next
- OnePlus Snapdragon devices with unlocked bootloader

## Usage
Install via KernelSU module manager, then reboot. The fix runs automatically in the background. To manually trigger the fix, use the Action button in KernelSU.

## Disclaimer
This module is free. Based on GPL-2.0 licensed work.

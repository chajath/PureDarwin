#!/bin/sh
# Wrapper for org.puredarwin.serial.plist: just exec login bash.
# Boot-time init is handled by org.puredarwin.pdinit.plist.
exec /bin/bash --login

cmake_minimum_required(VERSION 3.20)

# Network components placeholder.
# This will eventually contain:
# - virtio-net kext (IOKit driver for QEMU networking)
# - DNS resolver (lightweight, no mDNSResponder dependency)
# - OpenSSL/LibreSSL build

message(STATUS "Network: components built via ../scripts/build-network.sh")

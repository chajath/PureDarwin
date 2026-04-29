cmake_minimum_required(VERSION 3.20)
project(PureDarwin-Userland C)

# PureDarwin Userland Upgrade Project
# Builds modern Unix userland components targeting Darwin 17 / x86_64
#
# Usage:
#   mkdir build && cd build
#   cmake .. -DCMAKE_TOOLCHAIN_FILE=../toolchain-darwin-x86_64.cmake
#   make

set(PD_SYSROOT "${CMAKE_CURRENT_SOURCE_DIR}/sysroot" CACHE PATH "PureDarwin sysroot for cross-compilation")
set(PD_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/rootfs" CACHE PATH "Installation root filesystem")

# All userland subprojects
add_subdirectory(init)
add_subdirectory(shell)
add_subdirectory(coreutils)
add_subdirectory(network)

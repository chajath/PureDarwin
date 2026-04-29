cmake_minimum_required(VERSION 3.20)

# pd_init: Minimal BSD-style init for PureDarwin
# Replaces launchd (which requires closed-source XPC)
# Based on FreeBSD/sinit design - pure POSIX, no XPC dependency

add_executable(pd_init
    pd_init.c
)

target_compile_options(pd_init PRIVATE -Wall -Wextra -Os)

install(TARGETS pd_init DESTINATION sbin)

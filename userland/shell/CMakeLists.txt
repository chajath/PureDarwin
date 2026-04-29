cmake_minimum_required(VERSION 3.20)

# Shell: Build bash or mksh for PureDarwin
# We use mksh as the default because it's tiny, portable, and POSIX-compliant.
# bash is also supported as an alternative.

include(ExternalProject)

set(MKSH_VERSION "R59c")
set(MKSH_URL "https://www.mirbsd.org/MirOS/dist/mir/mksh/mksh-${MKSH_VERSION}.tgz")

ExternalProject_Add(mksh
    URL ${MKSH_URL}
    CONFIGURE_COMMAND ""
    BUILD_IN_SOURCE TRUE
    BUILD_COMMAND sh Build.sh -r
    INSTALL_COMMAND ""
)
# After build, mksh binary is in the source dir.
# Install step handled by rootfs assembly script.

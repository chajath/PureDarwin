# PureDarwin cross-compilation toolchain for x86_64 Darwin
# Use with: cmake -DCMAKE_TOOLCHAIN_FILE=toolchain-darwin-x86_64.cmake

set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Use host clang with cross-compilation target
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET x86_64-apple-darwin17)
set(CMAKE_CXX_COMPILER_TARGET x86_64-apple-darwin17)

set(CMAKE_OSX_ARCHITECTURES x86_64)
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13")

# For static builds during bootstrap (no dyld dependency)
option(PD_STATIC_BOOTSTRAP "Build statically linked binaries for bootstrap" ON)

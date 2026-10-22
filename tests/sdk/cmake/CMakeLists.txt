# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Builds with share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake; ctest
# runs the tests under CMAKE_CROSSCOMPILING_EMULATOR (qemu-riscv64).
cmake_minimum_required(VERSION 3.20)
project(sdk_cmake_test C CXX)

enable_testing()
add_executable(hello_c ../hello.c)
add_executable(hello_cpp ../hello.cpp)
add_test(NAME hello_c COMMAND hello_c)
set_tests_properties(hello_c PROPERTIES PASS_REGULAR_EXPRESSION "hello from C")
add_test(NAME hello_cpp COMMAND hello_cpp)
set_tests_properties(hello_cpp PROPERTIES PASS_REGULAR_EXPRESSION "hello from C\\+\\+")

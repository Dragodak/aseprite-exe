# ASEPRITE
# Copyright (C) 2020-present  Igara Studio S.A.

# Aseprite version
set(ASEPRITE_VERSION "1.x" CACHE STRING "Base Aseprite version")
set(DRAGLUS_VERSION_SUFFIX "draglus-dev" CACHE STRING
  "Suffix added to the Aseprite version")

option(UPDATE_VERSION_WITH_GIT
  "Update Aseprite version using the Git checkout" on)

if(UPDATE_VERSION_WITH_GIT)
  find_package(Git QUIET)
  if(Git_FOUND)
    execute_process(
      COMMAND "${GIT_EXECUTABLE}" describe --tags --always --dirty
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      OUTPUT_VARIABLE GIT_VERSION
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE GIT_RESULT)

    if(GIT_RESULT EQUAL 0 AND NOT GIT_VERSION STREQUAL "")
      set(ASEPRITE_VERSION "${GIT_VERSION}")
    endif()
  endif()
endif()

# Git describes a modified checkout as "-dirty". That implementation detail
# must not leak into the product version; Draglus is the deliberate build label.
string(REGEX REPLACE "^v" "" ASEPRITE_VERSION "${ASEPRITE_VERSION}")
string(REGEX REPLACE "-dirty$" "" ASEPRITE_VERSION "${ASEPRITE_VERSION}")
string(REGEX REPLACE "-draglus(-dev)?$" "" ASEPRITE_VERSION "${ASEPRITE_VERSION}")
string(REGEX REPLACE "-dev$" "" ASEPRITE_VERSION "${ASEPRITE_VERSION}")

if(ASEPRITE_VERSION STREQUAL "")
  set(ASEPRITE_VERSION "1.x")
elseif(NOT ASEPRITE_VERSION MATCHES "^[0-9]+\\.[0-9]+")
  set(ASEPRITE_VERSION "1.x-${ASEPRITE_VERSION}")
endif()

if(DRAGLUS_VERSION_SUFFIX STREQUAL "")
  set(VERSION "${ASEPRITE_VERSION}")
else()
  set(VERSION "${ASEPRITE_VERSION}-${DRAGLUS_VERSION_SUFFIX}")
endif()

message(STATUS "Aseprite version: ${VERSION}")

configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/generated_version.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated_version.h")

add_library(ver-lib info.c ${gen_ver_fn})
target_include_directories(ver-lib PRIVATE .. "${CMAKE_CURRENT_BINARY_DIR}")

# Custom Aseprite website (for testing server-side)
if(NOT "${CUSTOM_WEBSITE_URL}" STREQUAL "")
  target_compile_definitions(ver-lib PRIVATE -DCUSTOM_WEBSITE_URL="${CUSTOM_WEBSITE_URL}")
endif()

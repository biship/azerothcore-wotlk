#
# This file is part of the AzerothCore Project. See AUTHORS file for Copyright information
#
# This file is free software; as a special exception the author gives
# unlimited permission to copy and/or distribute it, with or without
# modifications, as long as this notice is preserved.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY, to the extent permitted by law; without even the
# implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
#set(Boost_DEBUG 1)

if(WIN32)
  if(DEFINED ENV{Boost_ROOT})
    message(NOTICE "Boost_ROOT defined.")
    set(Boost_ROOT $ENV{Boost_ROOT})
	# --- Fix Boost detection for MSVC 2022 + C++23 ---
    #set(Boost_NO_BOOST_CMAKE ON)
    #set(Boost_NO_SYSTEM_PATHS OFF)
    #set(Boost_DETAILED_FAILURE_MSG OFF)
    #set(BOOST_ROOT "C:/ProgramData/boost")
    #set(BOOST_INCLUDEDIR "C:\\ProgramData\\boost")
    #set(BOOST_LIBRARYDIR "C:\\ProgramData\\boost\\lib64-msvc-14.3")
  endif()

  set(Boost_USE_STATIC_LIBS        ON)
  set(Boost_USE_MULTITHREADED      ON)
  set(Boost_USE_STATIC_RUNTIME     OFF)
endif()

set(Boost_NO_WARN_NEW_VERSIONS ON)

include (CheckCXXSourceCompiles)

if (WIN32)
  # On windows the requirements are higher according to the wiki.
  set(BOOST_REQUIRED_VERSION 1.78)
else()
  set(BOOST_REQUIRED_VERSION 1.74)
endif()

# Boost.System is header-only since 1.69; do not require it explicitly.
find_package(Boost ${BOOST_REQUIRED_VERSION} REQUIRED COMPONENTS filesystem program_options iostreams regex thread)
# Modern Boost (≥1.82) has many header-only libs; request only those actually needed.
#find_package(Boost ${BOOST_REQUIRED_VERSION} REQUIRED COMPONENTS filesystem program_options)

if(NOT Boost_FOUND)
  if(NOT DEFINED ENV{Boost_ROOT} AND NOT DEFINED Boost_DIR AND NOT DEFINED BOOST_ROOT AND NOT DEFINED BOOSTROOT)
    message(FATAL_ERROR "No Boost_ROOT environment variable could be found! Please make sure it is set and the points to your Boost installation.")
  endif()
else()
  message(NOTICE "Boost_ROOT good.")
endif()

add_library(boost INTERFACE)

target_link_libraries(boost
  INTERFACE
    ${Boost_LIBRARIES})

target_include_directories(boost
  INTERFACE
    ${Boost_INCLUDE_DIRS})

target_compile_definitions(boost
  INTERFACE
    -DBOOST_DATE_TIME_NO_LIB
    -DBOOST_REGEX_NO_LIB
    -DBOOST_CHRONO_NO_LIB
    -DBOOST_SERIALIZATION_NO_LIB
    -DBOOST_CONFIG_SUPPRESS_OUTDATED_MESSAGE
    -DBOOST_ASIO_NO_DEPRECATED
    -DBOOST_SYSTEM_USE_UTF8
    -DBOOST_BIND_NO_PLACEHOLDERS)

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

if(NOT EXISTS "@CMAKE_CURRENT_BINARY_DIR@/install_manifest.txt")
  message(FATAL_ERROR "Cannot find install manifest: \"@CMAKE_CURRENT_BINARY_DIR@/install_manifest.txt\"")
endif()

file(READ "@CMAKE_CURRENT_BINARY_DIR@/install_manifest.txt" files)
string(REGEX REPLACE "\n" ";" files "${files}")

foreach(file ${files})
  message(STATUS "Uninstalling \"${file}\"")
  if(EXISTS "${file}")
    execute_process(
      COMMAND "@CMAKE_COMMAND@" -E remove "${file}"
      RESULT_VARIABLE rm_retval
      OUTPUT_VARIABLE rm_out
      ERROR_VARIABLE rm_err
    )
    if(NOT rm_retval EQUAL 0)
      message(FATAL_ERROR "Problem when removing \"${file}\": ${rm_err}")
    endif()
  else()
    message(STATUS "File \"${file}\" does not exist.")
  endif()
endforeach()

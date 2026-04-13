cmake_minimum_required(VERSION 3.22)
project(dx_wrapper VERSION 2.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_SHARED_LINKER_FLAGS
    "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--no-undefined -Wl,-z,now -Wl,-z,relro")

find_library(LOG_LIB     log     REQUIRED)
find_library(ANDROID_LIB android REQUIRED)

set(GLSLC "" CACHE STRING "Path to glslc shader compiler")
if(NOT GLSLC)
    find_program(GLSLC glslc HINTS
        "${ANDROID_NDK}/shader-tools/${ANDROID_HOST_TAG}"
        "$ENV{VULKAN_SDK}/bin"
        "/usr/bin" "/usr/local/bin")
endif()

if(GLSLC)
    message(STATUS "glslc found: ${GLSLC}")
    set(SHADER_SRC  "${CMAKE_SOURCE_DIR}/src/shaders/bcn_decompress.comp.glsl")
    set(SHADER_SPV  "${CMAKE_BINARY_DIR}/bcn_decompress.comp.spv")
    add_custom_command(
        OUTPUT  "${SHADER_SPV}"
        COMMAND "${GLSLC}"
                --target-env=vulkan1.1
                -fshader-stage=compute
                -O
                "${SHADER_SRC}"
                -o "${SHADER_SPV}"
        DEPENDS "${SHADER_SRC}"
        COMMENT "Compiling BCn compute shader → SPIR-V"
    )
    add_custom_target(compile_shaders DEPENDS "${SHADER_SPV}")
else()
    message(WARNING "glslc not found — skipping compute shader compilation")
    add_custom_target(compile_shaders)
endif()

set(WRAPPER_SOURCES
    src/wrapper_core.cpp
    src/dxvk_compat.cpp
    src/present_manager.cpp
    src/bcn_decompressor.cpp
    src/spirv_patcher.cpp
)

add_library(vulkan_wrapper SHARED ${WRAPPER_SOURCES})
add_dependencies(vulkan_wrapper compile_shaders)

target_include_directories(vulkan_wrapper PRIVATE
    src/include
    ${ANDROID_NDK}/sources/third_party/vulkan/src/include
)

target_compile_options(vulkan_wrapper PRIVATE
    -Wall -Wextra
    -fvisibility=hidden
    -ffunction-sections
    -fdata-sections
    -Os
    -fno-exceptions
    -fno-rtti
)

target_link_options(vulkan_wrapper PRIVATE
    -Wl,--gc-sections
    -Wl,-s
)

target_link_libraries(vulkan_wrapper PRIVATE
    ${LOG_LIB}
    ${ANDROID_LIB}
)

set_target_properties(vulkan_wrapper PROPERTIES
    OUTPUT_NAME "vulkan_wrapper"
    SUFFIX ".so"
    PREFIX "lib"
)

install(TARGETS vulkan_wrapper DESTINATION lib)
if(GLSLC)
    install(FILES "${SHADER_SPV}" DESTINATION lib)
endif()

message(STATUS "DX Wrapper v${PROJECT_VERSION} | ABI=${ANDROID_ABI} | API=${ANDROID_NATIVE_API_LEVEL}")

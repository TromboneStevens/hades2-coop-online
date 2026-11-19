add_library(HadesCoopGame SHARED)

add_definitions(-DEASTL_DEBUG=0)
add_definitions(-DEASTL_CUSTOM_FLOAT_CONSTANTS_REQUIRED)

include_directories (
   src/.
   ../include
   ../libs/lua-5.2.2/src
   ../libs/hades2-engine-interface/src
)

file(GLOB_RECURSE MOD_FILES src/*.cpp src/*.h)

target_sources(
    HadesCoopGame
    PUBLIC
        ${MOD_FILES}
)

target_link_libraries(HadesCoopGame PRIVATE liblua Hades2EngineInterface)

if(WIN32)
    # Winsock2 used by src/net/NetTransport.cpp for the online coop transport.
    target_link_libraries(HadesCoopGame PRIVATE ws2_32)
endif()
target_precompile_headers(HadesCoopGame PRIVATE src/pch.h)

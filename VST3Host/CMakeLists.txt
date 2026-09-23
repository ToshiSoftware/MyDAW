cmake_minimum_required(VERSION 3.25)

project(MyDAWVST3Host LANGUAGES CXX OBJCXX)

set(VST3_SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../ThirdParty/vst3sdk")

set(SMTG_ENABLE_VST3_PLUGIN_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VST3_HOSTING_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VSTGUI_SUPPORT OFF CACHE BOOL "" FORCE)

add_subdirectory("${VST3_SDK_ROOT}" "${CMAKE_BINARY_DIR}/vst3sdk" EXCLUDE_FROM_ALL)

add_library(MyDAWVST3Bridge STATIC
    VST3HostBridge.cpp
    VST3PluginInstance.cpp
    "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/plugprovider.cpp"
    "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/hostclasses.cpp"
    "${VST3_SDK_ROOT}/public.sdk/source/common/memorystream.cpp"
    "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/module_mac.mm"
)

set_source_files_properties(
    "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/module_mac.mm"
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)

target_compile_features(MyDAWVST3Bridge PRIVATE cxx_std_17)
target_link_libraries(
    MyDAWVST3Bridge
    PRIVATE
        sdk_hosting
        "-framework CoreFoundation"
        "-framework Foundation"
)
target_include_directories(MyDAWVST3Bridge PRIVATE "${VST3_SDK_ROOT}")

add_executable(MyDAWVST3Probe VST3HostProbe.cpp)
target_compile_features(MyDAWVST3Probe PRIVATE cxx_std_17)
target_link_libraries(MyDAWVST3Probe PRIVATE MyDAWVST3Bridge)
target_include_directories(MyDAWVST3Probe PRIVATE "${VST3_SDK_ROOT}")

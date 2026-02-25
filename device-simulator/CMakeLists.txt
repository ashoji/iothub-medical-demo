cmake_minimum_required(VERSION 3.10)
project(IoTHubDeviceSimulator C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Azure IoT SDK のインクルードとライブラリの設定
include_directories(/usr/local/include/azureiot)
include_directories(/usr/local/include)
link_directories(/usr/local/lib)

# Azure IoT SDK ライブラリ（依存関係の順序が重要）
set(AZURE_IOT_LIBS
    iothub_client
    iothub_client_mqtt_transport
    umqtt
    aziotsharedutil
    parson
    uamqp
)

# 必要なライブラリ
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)

# 実行ファイルの作成
add_executable(device_simulator device_simulator.c)

# インクルードディレクトリ
target_include_directories(device_simulator PRIVATE
    ${OPENSSL_INCLUDE_DIR}
    ${CURL_INCLUDE_DIRS}
)

# ライブラリのリンク
target_link_libraries(device_simulator
    ${AZURE_IOT_LIBS}
    ${CMAKE_THREAD_LIBS_INIT}
    ${OPENSSL_LIBRARIES}
    ${CURL_LIBRARIES}
    uuid
    m
    pthread
    dl
)

# コンパイルオプション
target_compile_options(device_simulator PRIVATE -Wall -Wextra)

# インストール設定
install(TARGETS device_simulator DESTINATION bin)

message(STATUS "Configuration complete")
message(STATUS "Build with: cmake --build .")
message(STATUS "Run with: ./device_simulator <device_name> <mode> [options]")

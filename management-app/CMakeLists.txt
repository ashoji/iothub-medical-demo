cmake_minimum_required(VERSION 3.10)
project(device_manager_c)

set(CMAKE_C_STANDARD 11)

# 実行ファイルの作成
add_executable(device_manager device_manager.c)

# インクルードディレクトリの追加
target_include_directories(device_manager PRIVATE
    /usr/local/include
    /usr/local/include/azureiot
    /usr/local/include/iothub_service_client
)

# Azure IoT SDK のリンク
target_link_libraries(device_manager
    /usr/local/lib/libiothub_service_client.a
    /usr/local/lib/libuamqp.a
    /usr/local/lib/libaziotsharedutil.a
    /usr/local/lib/libumqtt.a
    /usr/local/lib/libparson.a
    pthread
    curl
    ssl
    crypto
    uuid
    m
)

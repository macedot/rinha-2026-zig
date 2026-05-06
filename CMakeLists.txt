cmake_minimum_required(VERSION 3.20)
project(rinha_backend C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Mac Mini Late 2014 2.6GHz = Intel Haswell.
# Evita gerar instruções da sua máquina atual que podem quebrar na máquina de teste.
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -O3 -march=haswell -mtune=haswell -flto -fomit-frame-pointer -DNDEBUG")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -O0 -g")

add_executable(rinha_backend
        src/main.c
        src/config.c
        src/dataset.c
        src/mcc_risk.c
        src/vectorizer.c
        src/ivf_search.c
        src/http_responses.c
        src/iouring_server.c
)

target_link_libraries(rinha_backend PRIVATE uring z m)

add_executable(build_index
        src/build_index.c
)

target_link_libraries(build_index PRIVATE z m)
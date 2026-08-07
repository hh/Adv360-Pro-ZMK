FROM docker.io/zmkfirmware/zmk-build-arm:stable

WORKDIR /app

COPY config/west.yml config/west.yml

# West Init
RUN west init -l config
# West Update
RUN west update
# zmk-hogp needs LE Legacy pairing possible; upstream forces SC-only (see zmk-hogp/README.md)
RUN cd zmk && patch -p1 < ../zmk-hogp/patches/zmk-sc-pair-only.patch
# West Zephyr export
RUN west zephyr-export

COPY bin/build.sh ./

CMD ["./build.sh"]

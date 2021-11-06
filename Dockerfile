FROM         balenalib/jetson-nano-ubuntu-node:16-bionic AS base
WORKDIR     /tmp/workdir

ENV     DEBIAN_FRONTEND=noninteractive
RUN	apt-get -yqq update && \
    mkdir -p /opt/nvidia/l4t-packages/ && \
    touch /opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall && \
    echo '#!/bin/sh\nsu -c "$*"' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo && \
        echo "/usr/lib/aarch64-linux-gnu/tegra" > /etc/ld.so.conf.d/aarch64-linux-gnu_GL.conf && ldconfig && \
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew install \
        --no-install-recommends ca-certificates expat libgomp1 cmake xz-utils rsync gnupg git wget libv4l-dev libegl1-mesa-dev \
    nvidia-l4t-jetson-multimedia-api nvidia-l4t-multimedia nvidia-l4t-cuda nvidia-l4t-3d-core nvidia-l4t-wayland libffi6 && \
        apt-get autoremove -y && \
        apt-get clean -y

ENV UDEV=1

FROM base as build

ENV     FFMPEG_VERSION=4.3.1 \
        FREETYPE_VERSION=2.11.0 \
        LAME_VERSION=3.100 \
        LIBPTHREAD_STUBS_VERSION=0.4 \
        SRC=/usr/local

ARG         LD_LIBRARY_PATH=/opt/ffmpeg/lib
ARG         MAKEFLAGS="-j4"
ARG         PKG_CONFIG_PATH="/opt/ffmpeg/share/pkgconfig:/opt/ffmpeg/lib/pkgconfig:/opt/ffmpeg/lib64/pkgconfig"
ARG         PREFIX=/opt/ffmpeg
ARG         LD_LIBRARY_PATH="/opt/ffmpeg/lib:/opt/ffmpeg/lib64:/usr/lib64:/usr/lib:/lib64:/lib"

#RUN	echo "deb https://repo.download.nvidia.com/jetson/common r32.6 main" \
#	 > /etc/apt/sources.list.d/nvidia-l4t-apt-source.list && \
#	echo "deb https://repo.download.nvidia.com/jetson/t210 r32.6 main" \
#	 >> /etc/apt/sources.list.d/nvidia-l4t-apt-source.list
#
#RUN	apt-key adv --fetch-key https://repo.download.nvidia.com/jetson/jetson-ota-public.asc && \

RUN     buildDeps="autoconf \
        automake \
        curl \
        bzip2 \
        libexpat1-dev \
        g++ \
        gcc \
        gperf \
        libtool \
        make \
        nasm \
        perl \
        pkg-config \
        python \
        libssl-dev \
        yasm \
        libomxil-bellagio-dev \
        zlib1g-dev" && \
        apt-get -yqq update && \
        apt-get install -yq --no-install-recommends ${buildDeps}
#
## Nvidia Jetson hwaccel https://github.com/jocover/jetson-ffmpeg
RUN	DIR=/tmp/jetson-ffmpeg && \
     mkdir -p ${DIR} && \
     cd ${DIR} && \
     git clone https://github.com/jocover/jetson-ffmpeg.git && \
     cd jetson-ffmpeg && \
     mkdir build && \
     cd build && \
     cmake -DCMAKE_INSTALL_PREFIX:PATH="${PREFIX}" .. && \
     make -j $(nproc) && \
     make -j $(nproc) install && \
     ldconfig && \
     git clone git://source.ffmpeg.org/ffmpeg.git -b release/4.2 --depth=1 && \
     cd ffmpeg && \
     wget https://github.com/jocover/jetson-ffmpeg/raw/master/ffmpeg_nvmpi.patch && \
     git apply ffmpeg_nvmpi.patch && \
     ./configure --enable-nvmpi && \
     make install
#&& \
#     rm -rf ${DIR}

## freetype https://www.freetype.org/
#        curl -sLO https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.gz && \

RUN  \
        DIR=/tmp/freetype && \
        mkdir -p ${DIR} && \
        cd ${DIR} && \
        curl -sLO https://mirror.yongbok.net/nongnu/freetype/freetype-2.11.0.tar.gz && \
        tar -zx --strip-components=1 -f freetype-2.11.0.tar.gz && \
        ./configure --prefix="${PREFIX}" --disable-static --enable-shared && \
        make -j $(nproc) && \
        make -j $(nproc) install && \
        rm -rf ${DIR}

RUN \
        DIR=/tmp/libpthread-stubs && \
        mkdir -p ${DIR} && \
        cd ${DIR} && \
        curl -sLO https://xcb.freedesktop.org/dist/libpthread-stubs-${LIBPTHREAD_STUBS_VERSION}.tar.gz && \
        tar -zx --strip-components=1 -f libpthread-stubs-${LIBPTHREAD_STUBS_VERSION}.tar.gz && \
        ./configure --prefix="${PREFIX}" && \
        make -j $(nproc) && \
        make -j $(nproc) install && \
        rm -rf ${DIR}

## ffmpeg https://ffmpeg.org/
RUN	DIR=/tmp/ffmpeg && mkdir -p ${DIR} && cd ${DIR} && \
    curl -sLO https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2 && \
    tar -jx --strip-components=1 -f ffmpeg-${FFMPEG_VERSION}.tar.bz2 && \
    wget -q https://raw.githubusercontent.com/e1z0/jetson-frigate/main/ffmpeg/nvmpi.patch && \
        patch -p1 < nvmpi.patch

RUN	DIR=/tmp/ffmpeg && mkdir -p ${DIR} && cd ${DIR} && \
        ./configure \
    --enable-nvmpi \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --enable-shared \
        --enable-avresample \
        --enable-gpl \
        --enable-libfreetype \
        --enable-nonfree \
    --disable-libxcb \
    --disable-libxcb-shm \
    --disable-libxcb-xfixes \
    --disable-libxcb-shape \
        --enable-openssl \
        --enable-postproc \
        --enable-version3 \
        --extra-libs=-ldl \
        --prefix="${PREFIX}" \
#        --extra-libs=-lpthread \
        --enable-neon \
        --extra-cflags="-I${PREFIX}/include -I /usr/src/jetson_multimedia_api/include/" \
        --extra-ldflags="-L${PREFIX}/lib -L/usr/lib/aarch64-linux-gnu/tegra -lnvbuf_utils" && \
        make -j $(nproc) && \
        make -j $(nproc) install && \
        make distclean && \
        hash -r

## cleanup
RUN \
        ldd ${PREFIX}/bin/ffmpeg | grep opt/ffmpeg | cut -d ' ' -f 3 | xargs -i cp {} /usr/local/lib/ && \
        for lib in /usr/local/lib/*.so.*; do ln -s "${lib##*/}" "${lib%%.so.*}".so; done && \
        cp -rv /opt/ffmpeg/lib/* /usr/local/lib/ && \
        cp ${PREFIX}/bin/* /usr/local/bin/ && \
        cp -r ${PREFIX}/share/ffmpeg /usr/local/share/ && ls /usr/local/lib && \
    ldd /usr/local/bin/ffmpeg && \
#        LD_LIBRARY_PATH=/usr/local/lib ffmpeg -buildconf && \
        cp -r ${PREFIX}/include/libav* ${PREFIX}/include/libpostproc ${PREFIX}/include/libsw* /usr/local/include && \
        mkdir -p /usr/local/lib/pkgconfig && \
        for pc in ${PREFIX}/lib/pkgconfig/libav*.pc ${PREFIX}/lib/pkgconfig/libpostproc.pc ${PREFIX}/lib/pkgconfig/libsw*.pc; do \
        sed "s:${PREFIX}:/usr/local:g" <"$pc" >/usr/local/lib/pkgconfig/"${pc##*/}"; \
        done

FROM        base AS release
# Run ffmpeg with -c:v h264_nvmpi to enable HW accell for decoding on Jetson Nano
ENV         LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/lib:/usr/lib64:/lib:/lib64:/usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra-egl
COPY --from=build /usr/local /usr/local/
ENV SCRYPTED_RASPBIAN_FFMPEG_PATH="/usr/local/bin/ffmpeg"


#Install scrypted
RUN apt-get -y update \
&&  apt-get -y upgrade \
&&  apt-get -y install libavahi-compat-libdnssd-dev build-essential libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev
WORKDIR /
RUN git clone https://github.com/koush/scrypted.git
WORKDIR scrypted/server
RUN npm install \
&& npm run build
ENV SCRYPTED_DOCKER_SERVE="true"
ENV SCRYPTED_CAN_RESTART="true"
CMD npm run serve-no-build

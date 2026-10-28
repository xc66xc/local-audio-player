#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Only Ogg Vorbis/Opus decoding and PCM output. No network protocols or GPL components.
DECODER_VERSION=8.1.2
DECODER_SHA=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
DECODER_ROOT="$PWD/.build/decoder"
DECODER_BUILD_KEY="$(shasum -a 256 build-decoder.sh | cut -d ' ' -f 1)-$(uname -m)-$(xcrun --show-sdk-version)"
mkdir -p "$DECODER_ROOT"
ARCHIVE="$DECODER_ROOT/ffmpeg-$DECODER_VERSION.tar.xz"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$DECODER_VERSION.tar.xz" -o "$ARCHIVE"
fi
printf '%s  %s\n' "$DECODER_SHA" "$ARCHIVE" | shasum -a 256 -c -
if [[ -x "$DECODER_ROOT/bin/ffmpeg" && -x "$DECODER_ROOT/bin/ffprobe" && -f "$DECODER_ROOT/build-key" && "$(cat "$DECODER_ROOT/build-key")" == "$DECODER_BUILD_KEY" ]]; then exit 0; fi
tar -xf "$ARCHIVE" -C "$DECODER_ROOT"
cd "$DECODER_ROOT/ffmpeg-$DECODER_VERSION"
export MACOSX_DEPLOYMENT_TARGET=13.0
./configure --prefix="$DECODER_ROOT" --disable-everything --disable-autodetect \
  --disable-network --disable-doc --disable-debug --disable-shared --disable-x86asm --enable-static \
  --disable-avdevice --disable-swscale --disable-videotoolbox --disable-audiotoolbox \
  --enable-ffmpeg --enable-ffprobe --enable-protocol=file,pipe --enable-demuxer=ogg \
  --enable-decoder=vorbis,opus --enable-parser=vorbis,opus --enable-encoder=pcm_f32le \
  --enable-muxer=pcm_f32le --enable-filter=abuffer,abuffersink,aresample,aformat,anull \
  --extra-cflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0 \
  > "$DECODER_ROOT/configure.log" 2>&1
make -j "$(sysctl -n hw.logicalcpu)" > "$DECODER_ROOT/make.log" 2>&1
mkdir -p "$DECODER_ROOT/bin"
cp ffmpeg ffprobe "$DECODER_ROOT/bin/"
strip "$DECODER_ROOT/bin/ffmpeg" "$DECODER_ROOT/bin/ffprobe"
cp COPYING.LGPLv2.1 "$DECODER_ROOT/FFmpeg-LICENSE.txt"
printf '%s\n' "$DECODER_BUILD_KEY" > "$DECODER_ROOT/build-key"

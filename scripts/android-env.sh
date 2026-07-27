#!/bin/bash
# Source this before any Android/backend build.
#
#   . /home/zmr233/01_Projects/15_Tools/12-Anki-Workspace/scripts/android-env.sh
#
# Every build here runs in the local shell. Only `adb` needs `ssh local`,
# because /dev/bus/usb is ACL'd to zmr233 — see CLAUDE.md.

export WORKSPACE=/home/zmr233/01_Projects/15_Tools/12-Anki-Workspace

export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# Must match `ndk` in 03-Anki-Android-Backend-Dev/gradle/libs.versions.toml.
# set-android-ndk-home.sh re-derives this itself, but exporting it lets the
# gradle/cargo builds work without going through that script.
export ANDROID_NDK_VERSION=29.0.14206865
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"

# AGP 8.13.2 (backend) / 9.0.1 (AnkiDroid) both want JDK 17+. The shell default
# is JDK 23, which is newer than either has been validated against; pin 21 LTS.
export JAVA_HOME="$HOME/.sdkman/candidates/java/21.0.6-amzn"

# Deliberately NOT setting PROTOC. Both repos pin it in .cargo/config.toml to
# anki's downloaded protoc (31.1), and a cargo [env] entry does not override an
# already-set variable. Pointing it at the system protoc (35.1) makes
# rslib-bridge generate Java that calls protobuf runtime APIs newer than the
# protobuf-kotlin-lite 4.33.5 that rsdroid depends on, and the AAR fails to
# compile with ~51 "cannot find symbol" errors.

export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin:$HOME/.cargo/bin:$PATH"

if [ -n "${ANDROID_ENV_VERBOSE:-}" ]; then
    echo "ANDROID_HOME=$ANDROID_HOME"
    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    echo "JAVA_HOME=$JAVA_HOME"
    java -version 2>&1 | head -1
fi

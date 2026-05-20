#!/bin/bash

# Variables
TEMP=$(mktemp -d)
BUILD_DIR=".theos/obj/debug"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SDK_URL="https://github.com/qianjigui/iOS-sdks/raw/refs/heads/master/iPhoneOS7.1.sdk/iPhoneOS7.1.sdk.zip"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Darwin (macOS) detected, use Xcode instead! This script is for Linux/Windows only."
    exit 1
fi

# Check if the app is built, if not build it first
if [ ! -d "$BUILD_DIR/Discord.app" ]; then
    echo "Building Discord Classic..."

    if [ ! -d "$THEOS" ]; then
        echo "Theos not found, please install Theos and try again."
        exit 1
    fi

    if ! command -v printf &> /dev/null; then
        echo "coreutils not found, please install coreutils and try again."
        exit 1
    fi

    if [ ! -d "$THEOS/sdks/iPhoneOS7.1.sdk" ]; then
        echo "iPhoneOS7.1 SDK not found, downloading and installing it..."
        wget -O "$TEMP/iPhoneOS7.1.sdk.zip.001" "$SDK_URL.001"
        wget -O "$TEMP/iPhoneOS7.1.sdk.zip.002" "$SDK_URL.002"
        wget -O "$TEMP/iPhoneOS7.1.sdk.zip.003" "$SDK_URL.003"
        wget -O "$TEMP/iPhoneOS7.1.sdk.zip.004" "$SDK_URL.004"
        wget -O "$TEMP/iPhoneOS7.1.sdk.zip.005" "$SDK_URL.005"
        cat "$TEMP/iPhoneOS7.1.sdk.zip."* > "$TEMP/iPhoneOS7.1.sdk.zip"
        unzip "$TEMP/iPhoneOS7.1.sdk.zip" -d "$THEOS/sdks/"
    fi
    
    # All good
    # Make sure to clean first just in case
    {
        make clean
        make -j$(nproc)
    } || {
        echo "Errors occurred during build, aborting."
        exit 1
    }
else
    echo "Using existing build at $BUILD_DIR/Discord.app"
    echo "  Note: if you want to rebuild the app please run 'make clean' first."
fi

mkdir -p "$TEMP/Payload/Discord.app"

cp -R "$BUILD_DIR/Discord.app/Discord" "$TEMP/Payload/Discord.app/"
cp -R "$BUILD_DIR/Discord.app/Bundles/Settings.bundle" "$TEMP/Payload/Discord.app/"
cp -R "DiscordClassic/en.lproj" "$TEMP/Payload/Discord.app/"
# cp -R "asu_pid.entitlements" "$TEMP/Payload/Discord.app/"

find "$BUILD_DIR/Discord.app/Images" -name "*.png" -exec cp {} "$TEMP/Payload/Discord.app/" \;

# Copy the images from Catalogs/Images.xcassets (they need specific names to work properly)
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon29.png" "$TEMP/Payload/Discord.app/AppIcon29x29.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon29-1.png" "$TEMP/Payload/Discord.app/AppIcon29x29~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon40.png" "$TEMP/Payload/Discord.app/AppIcon40x40.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon50.png" "$TEMP/Payload/Discord.app/AppIcon50x50~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon100.png" "$TEMP/Payload/Discord.app/AppIcon50x50@2x~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon57.png" "$TEMP/Payload/Discord.app/AppIcon57x57.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon114.png" "$TEMP/Payload/Discord.app/AppIcon57x57@2x.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon58.png" "$TEMP/Payload/Discord.app/AppIcon29x29@2x.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon58-1.png" "$TEMP/Payload/Discord.app/AppIcon29x29@2x~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon72.png" "$TEMP/Payload/Discord.app/AppIcon72x72~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon144.png" "$TEMP/Payload/Discord.app/AppIcon72x72@2x~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon80.png" "$TEMP/Payload/Discord.app/AppIcon40x40@2x.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon80-1.png" "$TEMP/Payload/Discord.app/AppIcon40x40@2x~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon76.png" "$TEMP/Payload/Discord.app/AppIcon76x76~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon152.png" "$TEMP/Payload/Discord.app/AppIcon76x76@2x~ipad.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/AppIcon.appiconset/icon120.png" "$TEMP/Payload/Discord.app/AppIcon60x60@2x.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/LaunchImage.launchimage/LaunchImage.png" "$TEMP/Payload/Discord.app/LaunchImage.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/LaunchImage.launchimage/LaunchImage-3.5inch-Retina.png" "$TEMP/Payload/Discord.app/LaunchImage@2x.png"
cp "$BUILD_DIR/Discord.app/Catalogs/Images.xcassets/LaunchImage.launchimage/LaunchImage-4inch-Retina.png" "$TEMP/Payload/Discord.app/LaunchImage-568h@2x.png"

GITHUB_API_URL="https://api.github.com/repos/Ayeris23/Discord-Classic/releases/latest"
IPA_URL=$(curl -s "$GITHUB_API_URL" | grep "browser_download_url" | cut -d '"' -f 4)
if [ -z "$IPA_URL" ]; then
    echo "Failed to find the latest IPA."
    exit 1
else
    echo "Downloading latest IPA from Ayeris' fork..."
    wget -O "$TEMP/latest.ipa" "$IPA_URL"
    unzip -q "$TEMP/latest.ipa" -d "$TEMP/latest"
fi

# We need a few files from the IPA that aren't in the source code (precompiled storyboards/nibs), so we'll extract them here
# TODO: As of writing this is the only thing preventing builds from being entirely made with Theos
#       There is no true cross-platform alternative to ibtool (and ones that do exist don't work for us because our storyboards/nibs are too old)
#       The solution (for now) is to copy them from an existing IPA
cp -R "$TEMP/latest/Payload/Discord.app/*.storyboardc" "$TEMP/Payload/Discord.app/"
cp -R "$TEMP/latest/Payload/Discord.app/*.nib" "$TEMP/Payload/Discord.app/"

# Other miscellaneous files
# TODO: What function do they serve? Are they necessary?
cp -R "$TEMP/latest/Payload/Discord.app/{emoji.json,FontAwesome.ttf}" "$TEMP/Payload/Discord.app/"

IPA_NAME="Discord Classic.ipa"
if [ -f "$IPA_NAME" ]; then
    i=1
    while [ -f "Discord Classic ($i).ipa" ]; do
        i=$((i + 1))
    done
    IPA_NAME="Discord Classic ($i).ipa"
fi
cd "$TEMP"
zip -ryu1 "$DIR/$IPA_NAME" Payload
cd "$DIR"
echo "IPA created: $IPA_NAME"

# Clean up
rm -rf "$TEMP"

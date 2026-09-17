# Building Discord Classic

Discord Classic can be built with two different tools: **Xcode** (macOS only) or **Theos** (Linux and Windows (WSL)). <br>
As long as you have at least Mac OS X 10.8.4, [Xcode version 5](https://archive.org/details/xcode5.1.1) and the [iPhoneOS7.1 SDK](https://github.com/qianjigui/iOS-sdks/tree/master/iPhoneOS7.1.sdk), you can build the app just like any other project.
As a result these instructions will not go into detail on how to build using Xcode.

## Theos
Theos is a cross-platform build system for creating Linux, Windows, macOS and (more importantly) iOS applications.
It allows people who don't necessarily own an Apple device to write and compile software (given the correct SDKs) for any version of macOS and iOS.

Before you continue, make sure to follow the instructions [here](https://theos.dev/docs/installation) to install Theos.

---

While Theos does come with a `make package` command that supposedly creates an IPA for you, it has been confirmed to create invalid packages as it doesn't actually copy the necessary assets into the right places. <br>
To make building much simpler, every manual step you would ever need to follow has been condensed into one script.

**All you need to do is run `theos.sh` (no need for root!) and an IPA file should pop out in the same directory.**
You can then install the IPA with whatever method you choose (ideviceinstaller is recommended).

### Important Notes
- The resulting app is not signed, this doesn't matter though as the app is confirmed to still function.
- The script assumes that the current directory is inside the repository, specifically `/path/to/Discord-Classic/src/`. If you run the script outside of that directory, there's a good chance it won't work.
- If not found, the script will automatically download the iPhoneOS7.1 SDK for you. This will require an Internet connection.
- Since Theos is not an accurate enough alternative for Xcode, Theos builds will need to extract certain files from the latest IPA release. These are:
  - Precompiled .storyboardc and .nib files (requires ibtool)
  - Info.plist (using the readable version stored in `src/Assets/Plists` causes the IPA to fail to install, with ideviceinstaller returning "IncorrectArchitecture")

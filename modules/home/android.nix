{ pkgs, ... }:
let
  # A JDK and Android SDK so a project's Gradle build (Kotlin compile, unit
  # tests) runs on this Mac instead of only in CI. The versions follow the
  # Android project this was added for, not a general preference: its Gradle
  # build compiles against compileSdk 36 with a Java 25 toolchain, and its CI
  # container installs Temurin 25.0.3, the build packaged here.
  jdk = pkgs.temurin-bin-25;

  # nixpkgs packages the SDK components itself; a composition is the whole
  # SDK directory Gradle reads through ANDROID_HOME. It is in the store and
  # therefore read-only, so it must already contain every component the build
  # asks for: the Android Gradle Plugin cannot download a missing build-tools
  # or platform into it, and fails naming the one it wanted. Add that version
  # here when a project moves.
  #
  # Only what a Gradle compile needs: no emulator, system images, NDK, or
  # CMake. platform-tools (adb) is part of every composition, but nothing here
  # puts the SDK on PATH, so it does not become the machine's `adb`.
  #
  # The SDK license acceptance and the unfree allowance these components need
  # are nixpkgs settings, so they are declared with the system's nixpkgs in
  # ../darwin/nix.nix (Home Manager uses the global pkgs and cannot set them).
  androidSdk =
    (pkgs.androidenv.composeAndroidPackages {
      platformVersions = [ "36" ];
      buildToolsVersions = [ "36.0.0" ];
      includeEmulator = false;
      includeSystemImages = false;
      includeNDK = false;
      includeCmake = false;
    }).androidsdk;
  androidHome = "${androidSdk}/libexec/android-sdk";
in
{
  home.packages = [ jdk ];

  home.sessionVariables = {
    JAVA_HOME = jdk.home;
    ANDROID_HOME = androidHome;
    # Deprecated by Google in favour of ANDROID_HOME, but older tools read
    # only this one; both name the same directory.
    ANDROID_SDK_ROOT = androidHome;
  };
}

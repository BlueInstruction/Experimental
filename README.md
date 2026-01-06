# Mesa Turnip Driver for Android (Adreno 6xx/7xx)

Automated build repository for Mesa 25.3.3 optimized for Adreno 7xx/750 GPUs.
Designed for use with Android Emulators like Winlator, Cmod, and Mobox.

## Features
* **Version:** Mesa 25.3.3 (Stable)
* **Driver:** Turnip (Vulkan)
* **Backend:** KGSL (Kernel Graphics Support Layer)
* **Optimizations:** LTO enabled, Release build, Strip enabled.

## Build Usage
1.  Fork this repository.
2.  Go to **Actions** tab.
3.  Select **Build Mesa Turnip Android**.
4.  Run Workflow.
5.  Download the ZIP from the resulting Artifacts.

## Installation in Winlator
1.  Extract the downloaded ZIP.
2.  Import the JSON/SO file via the Winlator driver settings or place manually in the driver folder.

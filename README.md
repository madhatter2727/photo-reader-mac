# Photo Reader (Mac)

A native Mac app that describes a photo, a screenshot, or one page of a PDF, pulls out the words, and lets you ask follow-up questions. The picture stays on this Mac. A local vision model, MiniCPM-V 4.7 1B, does the reading.

This is the Mac app. The browser version lives next door at `../photo-reader/`.

## Build

macOS 14 or later. Command Line Tools are enough. There is no Xcode project.

```bash
cd ~/Projects/photo-reader-mac
swift build -c release
```

Install a double-clickable app, sign it ad hoc, and open it:

```bash
./Scripts/install-app.sh
```

That builds a release, quits Photo Reader if it is open, and copies the binary plus `Resources/Info.plist` into `~/Applications/Photo Reader.app`.

You can also run the binary directly:

```bash
.build/release/PhotoReader
.build/release/PhotoReader ~/Desktop/screenshot.png
```

## Model server

Photo Reader talks to llama-server at `http://127.0.0.1:8093`. On launch it checks `GET /health`. If that is not up, it submits a launchd job named `com.tara.photoreader.model` that runs:

`~/src/llama.cpp/build/bin/llama-server`

with the MiniCPM-V 4.7 1B model and mmproj under `~/Models/minicpm-v47/`. The log is `~/Models/minicpm-v47/llama-server.log`.

The toolbar pill says **Model ready**, **Starting model…**, or **Model offline**. Offline has a Retry button. Quitting Photo Reader does not stop the server. One Space uses it too.

## Using it

Drop a png, jpg, jpeg, heic, webp, gif, tiff, or PDF on the window. You can also click the drop area, press ⌘O, or paste an image with ⌘V.

The picture is scaled so the longest side is about 1400 pixels, then sent to the model. A PDF page is rendered with PDFKit. The stepper under the preview picks the page. Page 1 is the default.

Two sections fill in one after the other: a short description, then the text in the image. Copy puts that text on the clipboard. Ask keeps the same picture attached and streams the answer.

## Open a file from another app

After the app has been installed and launched once:

```bash
open -a "Photo Reader" ~/Desktop/photo.png
```

A path on the command line is opened the same way and read automatically.

Nothing from the picture is uploaded.

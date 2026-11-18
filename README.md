# LyricPlayer

Open an English or Spanish recording on your iPhone, read along as it plays, and tap a timestamp to hear that passage again.
LyricPlayer transcribes with the multilingual Whisper base model on the phone.
The model ships inside the built app, so there’s no account, API key, or model selection on first launch.

## Review a recording

1. Open **Recordings** and choose the spoken language, **English** or **Español**.
2. Tap **Choose Audio** and pick a locally available, unprotected audio file from Files.
3. Keep the app open while it transcribes. When the review opens, tap **Play**, drag the slider, or tap a line to start listening from its timestamp.
4. Open a saved recording again to review it without transcribing it twice.

Recognition preserves the spoken language.
The timestamps mark the starts of phrases and are approximate.
Speech, noise, accents, and music can affect accuracy.
The importer uses the audio formats supported by the iPhone’s media frameworks, including common M4A, MP3, and WAV files.
It copies the audio and writes a plain-text LRC transcript in **Files → On My iPhone → LyricPlayer → Recordings**.
Remove a recording’s folder there to reclaim its storage.
A second import with the same title creates a separate entry.

## Install or build

LyricPlayer is an open-source iPhone app for **iOS 17 or later**.
Distribution is currently through source builds.
There is no public TestFlight invitation or App Store listing for this release.

On a Mac with Xcode, Python 3, and an iOS SDK installed:

1. Clone this repository and run `python3 scripts/prepare.py --download` in its root.
   This explicitly fetches the official whisper.cpp v1.8.4 XCFramework and the approximately 148 MB multilingual base model and checks their SHA-256 digests.
   For offline setup, place `framework.zip` and `ggml-base.bin` in `Vendor/` and run `python3 scripts/prepare.py`.
2. Open `LyricPlayer.xcodeproj`, select the **LyricPlayer** scheme and an iPhone simulator, and press **Run**.
3. To run on your own iPhone, choose your development team and an available bundle identifier under the app target’s **Signing & Capabilities**, select your connected phone, and press **Run**.

The model and framework are build inputs, outside the repository’s Git history.
After installation, importing a local audio file and running Whisper work offline.

## Follow Apple Music

The **Music** tab follows the current track in the Music app and highlights lines from a matching LRC file.
Grant Music library access when opening that tab.
Put the LRC directly in LyricPlayer’s Documents folder in Files and name it after the track’s title.
You can copy an imported recording’s `transcript.lrc` there and rename it.

For an optional desktop workflow, install FFmpeg and whisper-cli, prepare the model as above, and run:

```sh
scripts/build_lyrics.sh --language es --track "/path/to/recording.mp3"
```

The helper writes an LRC to `lyrics/`.
On macOS it also accepts an exact Music track title with `--track`, or a playlist name without that option.
Set `WHISPER_BIN`, `WHISPER_MODEL`, or `LYRIC_OUT_DIR` to override its defaults.

## Verify

On macOS, run `scripts/test_audio.sh` with FFmpeg and the Samantha and Mónica system voices to generate original English M4A and Spanish WAV fixtures locally.
In Xcode select an iPhone simulator and press **Command-U**.
The tests exercise transcription with the bundled model, recognized words in each language, saving and reopening, seeking in both directions, malformed input, and Apple Music transcript matching.
The bilingual integration test skips if the fixtures have not been generated.

## License

LyricPlayer’s source is licensed under [Apache-2.0](LICENSE).
The bundled engine and model retain their upstream MIT licenses. [Third-party notices](ThirdPartyNotices.txt).

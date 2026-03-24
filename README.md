<p align="center">
  <br>
  <img src="orchid.svg" alt="Lockpaw mascot" width="96" />
  <br>
</p>

<h1 align="center">Orchid</h1>

<p align="center">
  <strong>Screenshot then OCR, seamlessly</strong><br>
</p>


## Install

Requires macOS 15+.

### Using Homebrew (Recommended)

```sh
brew tap blossom-slopware/orchid
brew install --cask orchid
```

To upgrade:

```sh
brew upgrade --cask blossom-slopware/orchid/orchid
```

**Notes**:

- This app is **not** small. It automatically downloads a GLM-OCR checkpoint from huggingface (hf-mirror in China Mainland) at initial startup, which takes ~15 minutes and takes up ~2G disk space.
- After this initial download, it runs OCR inference on your own computer. Therefore, it is **completely** offline, but takes up a good chunk of memory.

### Use

`F4` to select a screen region to recognize.

### Manual Installation

Download the latest release from [GitHub Releases](https://github.com/GLM-OCR/orchid/releases) and extract `Orchid.app` to your Applications folder.


```toml
port = 14416

[model-path]
glm-ocr = "/path/to/your/checkpoint"
```

## Build from Source

```sh
./scripts/build_release.sh
```

Produces `build/Orchid-<VERSION>.zip` containing `Orchid.app` with the Rust inference server and Metal shaders bundled.

## Manual Configure

Configure your preferred port and model checkpoint paths in `~/.orchid/config.toml`.
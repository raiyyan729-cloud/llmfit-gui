# LLM Fit GUI

**Beta release.** This is an early version and may still have rough edges or bugs. Feedback and bug reports are welcome.

A Windows desktop app (PowerShell + WinForms) that wraps the [`llmfit`](https://github.com/) CLI to help you find, download, and benchmark local LLMs that will run well on your hardware.

## Features

- Recommends models sized for your GPU/CPU/RAM, shown in a sortable results grid.
- Downloads models directly into **LM Studio** or **Ollama**, or as a raw GGUF file.
- Looks up the actual available quantizations and file sizes from Hugging Face (rather than relying solely on `llmfit`'s estimate), so the size shown matches the size you get.
- Benchmarks a downloaded model's tokens/sec on your machine, starting LM Studio's local server automatically if needed.
- Supports an optional Hugging Face token for gated or private repositories.

## Requirements

- Windows with PowerShell 5.1 or later (included by default).
- [`llmfit`](https://pypi.org/project/llmfit/) CLI installed and available on your `PATH`.
- [LM Studio](https://lmstudio.ai/) and/or [Ollama](https://ollama.com/), for the download and benchmark features.

## Usage

Double-click **`Launch LLM Fit.vbs`** to start the app without a visible console window.

Alternatively, run it directly:

```powershell
powershell -NoProfile -File gui.ps1
```

## Files

- `gui.ps1` — main application.
- `Launch LLM Fit.vbs` — silent launcher (suppresses the PowerShell console window).

## Status

This project is in active development. Expect occasional bugs and breaking changes between releases.

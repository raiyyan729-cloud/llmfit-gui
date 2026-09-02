# LLM Fit GUI

A Windows desktop app (PowerShell + WinForms) that wraps the [`llmfit`](https://github.com/) CLI to help you find, download, and benchmark local LLMs that will actually run well on your hardware.

## What it does

- Recommends models sized for your GPU/CPU/RAM, with a sortable results grid.
- Downloads models straight into **LM Studio** or **Ollama**, or as a raw GGUF file.
- Resolves the real available quantizations and file sizes from Hugging Face directly (not just `llmfit`'s own estimate), so the size you see is the size you get.
- Benchmarks a downloaded model's real tokens/sec on your machine, auto-starting LM Studio's local server if needed.
- Optional Hugging Face token support for gated/private repos.

## Requirements

- Windows with PowerShell 5.1+ (built in).
- [`llmfit`](https://pypi.org/project/llmfit/) CLI installed and on your `PATH`.
- [LM Studio](https://lmstudio.ai/) and/or [Ollama](https://ollama.com/) installed, for the download/benchmark features.

## Running it

Double-click **`Launch LLM Fit.vbs`** — it starts `gui.ps1` with no visible console window.

Or run it directly:

```powershell
powershell -NoProfile -File gui.ps1
```

## Files

- `gui.ps1` — the app.
- `Launch LLM Fit.vbs` — silent launcher (no PowerShell console window).

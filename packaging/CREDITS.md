# Credits and licences

Larynx itself is MIT (see `LICENSE`). It is built on the work below. This file travels inside the app
(`Larynx.app/Contents/Resources/Licenses/`), next to the licence texts of the code compiled into it.

## Speech models

Larynx does not ship model weights. The model you choose is downloaded from Hugging Face the first time it is
needed, into `~/Library/Application Support/Larynx/models`, and runs on your Mac. Each model keeps its own licence.

| Model in Larynx | Made by | Licence | Downloaded from | When it is used |
| --- | --- | --- | --- | --- |
| Parakeet Ultra (default) | moondream, post-trained from NVIDIA's Parakeet TDT 0.6B v3 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) (Core ML conversion of [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra)) | Always, unless you pick another model |
| Parakeet v3 | NVIDIA | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) (from [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)) | When you pick it |
| Parakeet Unified | NVIDIA | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) | [FluidInference/parakeet-unified-en-0.6b-coreml](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml) (from [nvidia/parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b)) | When you pick it |
| Bark Clean, Bark 3.0 | Conway Research (Underdog Bark 3.0), post-trained from Parakeet TDT 0.6B v3 | [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/): **non-commercial** | [FluidInference/bark-3.0-coreml](https://huggingface.co/FluidInference/bark-3.0-coreml) (from [ConwayResearch/Underdog-Bark-3.0](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0) and [-Clean](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean)) | When you pick it, or as the backup model if it is already downloaded |
| Parakeet CTC 110M (names from the screen) | NVIDIA | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) (from [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m)) | The screen-context pass |

Notes:

- The Bark models are licensed for non-commercial use only by Conway Research (commercial licences:
  license@conway.tech). Their Core ML conversion is tagged CC BY 4.0 on Hugging Face, but a conversion keeps the
  original's terms, so Larynx labels them non-commercial in Settings and the menu.
- Parakeet Unified is licensed by NVIDIA Corporation under the NVIDIA Open Model License. Its conversion is also
  tagged CC BY 4.0; the NVIDIA licence is the one that applies.
- The on-device AI rewrite uses Apple's Foundation Models framework, part of macOS. Larynx downloads nothing for it.

## Code compiled into Larynx

| Project | Licence | Where its text is |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) (runs the models on the Neural Engine) | Apache 2.0 | `FluidAudio/LICENSE` |
| Code that FluidAudio includes (fastcluster, NeMo text processing, word lists and others) | BSD, MIT, Apache 2.0, each listed | `FluidAudio/ThirdPartyLicenses/` |

## Data

| Data | Licence | Where its text is |
| --- | --- | --- |
| [SCOWL](https://wordlist.aspell.net/) English word list, the spelling fallback | Permissive (copyright notice kept) | `Larynx_LarynxText.bundle/.../SCOWL-Copyright.txt` |

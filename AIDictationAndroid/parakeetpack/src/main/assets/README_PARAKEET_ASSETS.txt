Place the local Parakeet payload for Android in this asset pack.

Current upstream bundle wired by the app:
- encoder-model.int8.onnx
- decoder_joint-model.int8.onnx
- nemo128.onnx
- vocab.txt

These files can be sourced from:
- https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx

Without those files, the app will request the pack and then fall back to remote transcription.

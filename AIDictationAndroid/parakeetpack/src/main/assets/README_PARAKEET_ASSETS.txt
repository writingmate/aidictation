Place the local Parakeet payload for Android in this asset pack.

Current ONNX bundle wired by the default local runtime:
- encoder-model.int8.onnx
- decoder_joint-model.int8.onnx
- nemo128.onnx
- vocab.txt

These files can be sourced from:
- https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx

Keep Android ONNX files saved with IR version 8. The bundled Android
ONNX Runtime rejects newer IR metadata before model execution.

LiteRT builds currently use a hybrid runtime: ONNX for preprocessor/encoder,
LiteRT for decoder/joint:
- nemo128.onnx
- encoder-model.int8.onnx
- decoder_model_float32.tflite
- joint_model_float32.tflite
- vocab.txt

Build a local LiteRT APK with:
./gradlew :app:assembleDebug -PPARAKEET_RUNTIME=litert -PTRANSCRIPTION_ENDPOINT= -PTRANSCRIPTION_MODEL=parakeet-tdt-0.6b-v3-litert

Without the runtime-specific model files, local Parakeet transcription fails fast with a missing-model error.

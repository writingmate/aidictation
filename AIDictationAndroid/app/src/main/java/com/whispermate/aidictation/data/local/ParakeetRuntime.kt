package com.whispermate.aidictation.data.local

enum class ParakeetRuntime(val configValue: String, val displayName: String) {
    ONNX("onnx", "ONNX"),
    LITERT("litert", "LiteRT");

    companion object {
        fun fromConfig(value: String?): ParakeetRuntime {
            return if (value.equals(LITERT.configValue, ignoreCase = true)) {
                LITERT
            } else {
                ONNX
            }
        }

        fun isLocalRuntime(value: String?): Boolean {
            return entries.any { runtime -> value.equals(runtime.configValue, ignoreCase = true) }
        }
    }
}

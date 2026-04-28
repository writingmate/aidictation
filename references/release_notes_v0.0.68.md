Fixes cloud transcription in the downloaded macOS build.

- Points AIDictation cloud transcription at the production-working Groq Whisper model.
- Keeps the production AIDictation proxy endpoint unchanged.
- Removes the broken OpenAI transcription model default that production rejected.

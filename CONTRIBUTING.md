# Contributing to AI Dictation

Thanks for helping improve AI Dictation. Contributions to the macOS, iOS, Windows, and Android apps are welcome.

## Before you start

1. Search [existing issues](https://github.com/writingmate/aidictation/issues) before opening a new one.
2. Open an issue before a substantial feature or architecture change so the expected user behavior is clear.
3. Read [AGENTS.md](AGENTS.md) and the [audio-processing failure contract](docs/audio-processing-failure-contract.md) before changing transcription, cleanup, recording, retry, deletion, or recovery behavior.

Do not attach private recordings, transcripts, credentials, access tokens, or customer data to public issues.

## Set up the project

Clone the repository:

```bash
git clone https://github.com/writingmate/aidictation.git
cd aidictation
```

Choose the platform you want to change:

- Apple platforms: open `Whishpermate/Whispermate.xcodeproj` in Xcode.
- Windows: open `AIDictation.Windows/AIDictation.sln` in Visual Studio.
- Android: open `AIDictationAndroid` in Android Studio or use its Gradle wrapper.

Platform-specific requirements and commands are in the [main README](README.md).

## Make a focused change

- Keep pull requests small enough to review.
- Preserve the user's transcript through its final token.
- Keep personal vocabulary and writing context available to cleanup in every supported pipeline.
- Use plain product language in user-facing copy.
- Never commit API keys, signing files, generated credentials, recordings, or transcripts.
- Add or update regression checks when behavior changes.

## Verify your work

Run the checks that cover the platform and behavior you changed. Audio-processing changes must cover every affected platform and the recovery cases described in `docs/audio-processing-failure-contract.md`.

In the pull request, include:

- What changed for the user.
- Which platforms are affected.
- How you tested the change.
- Screenshots or a short recording for visible UI changes.
- Any known limitations or follow-up work.

## Report a vulnerability

Do not open a public issue for a security or privacy vulnerability. Follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contribution will be licensed under the repository's [MIT License](LICENSE). Third-party code must keep its original copyright and license notices.

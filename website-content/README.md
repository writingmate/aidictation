# Website content staging

This directory contains content intended for the aidictation.com website. The website source lives in the private `writingmate/speak-it-fast` submodule.

## Integration instructions

### help/windows-microphone-permission.md

**Target URL:** `/faq/windows-microphone` or `/help/windows-microphone` (match existing routing)

**Steps to integrate:**

1. Open the `speak-it-fast` repository.
2. Add this help article using the same pattern as the existing FAQ page.
3. If the site has a `/faq` index, add a link to this new page from there.
4. Update the website submodule pointer in this repo after deploying.

**SEO metadata:**
- Title: `Windows Microphone Permission | AI Dictation Help`
- Description: `Fix microphone access issues on Windows. Enable the three privacy toggles so AI Dictation can hear you.`

**Structured data:** Consider adding FAQPage schema with these questions:
- "Why can't AI Dictation hear my microphone on Windows?"
- "How do I enable microphone access for AI Dictation on Windows?"

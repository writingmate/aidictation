# AI Dictation directory and distribution tracker

Last checked: 2026-08-02

Copy source: [`submission-pack.md`](submission-pack.md)

Machine-readable companion: [`directory-submissions.csv`](directory-submissions.csv)

LibHunt and freshcode.club now have verified live AI Dictation pages. SaaSHub
ownership is verified and its unsupported copy and old repository URL were
replaced. LocalAlternative, Open Source Startups, and NeuronFeed accepted
editorial-review submissions. The OpenAPK issue, Obtainium PR #1570, and Open
Source Observer PR #1140 are open for maintainer review, and a factual suggestion
was emailed to the Open Source Software Directory editor; none is counted as a
live listing yet. Internet Intro acknowledged a submission made before its
anti-campaigning rule was confirmed, so that receipt is recorded as a rule
mismatch and expected editorial rejection rather than a campaign win. The free
Launching Next and FOSShub forms remain prepared in preserved browser tabs but
require human CAPTCHA checks. Awesome-list pull requests are tracked separately
in `awesome-list-targets.md`.

## Status and evidence rules

- `LIVE—MAINTAIN`: an existing first-party or partner listing was verified.
- `LIVE—UPDATE`: an existing listing was verified and its copy or version is stale.
- `LIVE—CLAIM / UPDATE`: an existing listing needs owner verification and factual copy changes.
- `READY`: the route is available, but a human still needs to submit it.
- `PREPARED—HUMAN CHECK`: the form is filled and awaits a required CAPTCHA or equivalent owner action.
- `SUBMITTED—REVIEW`: the destination confirmed receipt and editorial review is pending.
- `SUBMITTED—RULE MISMATCH`: receipt exists, but a subsequently confirmed destination rule makes rejection the expected outcome; this is not counted as a successful placement.
- `RESEARCH / ASSET`: a valid target needs account, packaging, ownership, or media work first.
- `BLOCKED`: a concrete current blocker prevents submission.
- `DEFER—PAID`: no suitable free route was found.
- `DEFER—RECIPROCAL`: the free route requires a backlink or other product-site placement.
- `DEFER—LOW TRUST`: redirect behavior, weak editorial signals, or similar concerns make the target a poor early-wave choice.
- `NO FIT`: the current product or platform is outside the destination's stated scope.
- `AVOID`: poor fit or low-value behavior makes submission undesirable.

Presence and link evidence are separate:

- A live page, a search-indexed mirror, or an approved listing does **not** prove a dofollow backlink.
- `Dofollow: not verified` means no link-attribute claim should be made.
- Uneed markets backlink value, but its July 2026 changelog explicitly promises dofollow links for its paid skip-the-wait-line route. The free listing's link attribute is not verified.
- Some paid directories advertise dofollow links. That is the directory's commercial claim, not an independently inspected link on an AI Dictation listing.

### CSV contract

`directory-submissions.csv` has exactly one row per vetted target and a fixed 17-column schema:

1. `target_id`: stable lowercase kebab-case identifier.
2. `target_name`: display name.
3. `target_type`: normalized destination type.
4. `wave`: one of `existing`, `wave_1`, `wave_2`, or `deferred`.
5. `priority`: integer ordering within a wave (`0` for existing and `99` for deferred).
6. `action`: normalized next-action class.
7. `status`: normalized machine-readable form of the statuses above.
8. `listing_url`: verified or research-reported AI Dictation page; blank when none is claimed.
9. `submission_url`: primary form, account, documentation, or start URL.
10. `alternate_url`: secondary official route or evidence URL.
11. `blocking_condition`: snake-case blocker, prerequisite, or `none`.
12. `next_action`: single operational next step.
13. `listing_evidence`: what is known about an AI Dictation listing.
14. `index_evidence`: index/presence evidence, kept separate from link attributes.
15. `link_attribute_status`: `not_verified`, `not_applicable`, or a qualified directory claim.
16. `link_attribute_evidence`: plain-language limit on the link claim.
17. `last_checked`: ISO date.

## Existing listings: maintain, claim, or update

| Target | Type | Status | Listing | Form or account route | Blocker / next action | Listing evidence vs link evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Google Play | First-party app store | LIVE—MAINTAIN | https://play.google.com/store/apps/details?id=com.aidictation.app | https://play.google.com/console/ | Keep description, screenshots, privacy declarations, and release current through the owner account. | Live first-party listing verified; dofollow not applicable/not evaluated. |
| AppSumo | Partner marketplace | LIVE—UPDATE | https://appsumo.com/products/ai-dictation/ | Existing partner account; no public edit form captured | Listing is still positioned primarily as a Mac product. Request/update cross-platform copy and current privacy wording through the existing partner relationship. Do not copy its prices, metrics, language counts, or accuracy claims elsewhere. | Live indexed marketplace page verified; dofollow not verified. |
| APKPure | Third-party Android mirror | LIVE—UPDATE | https://apkpure.com/ai-dictation/com.aidictation.app | https://apkpure.com/request-update | Research found a stale `0.0.29` mirror, but the current browser safety policy blocks the official update route and prohibits alternate automation. The owner may use the official route manually; do not upload an unverified APK. | Existing indexed mirror verified; dofollow not verified. |
| APKCombo | Third-party Android mirror | LIVE—UPDATE | https://apkcombo.com/ai-dictation/com.aidictation.app/ | No verified publisher-claim route captured | Research found a stale `0.0.29` mirror. Confirm whether it is store-synced before requesting an update. Do not upload an unverified APK. | Existing indexed mirror reported; dofollow not verified. |
| SaaSHub | Software alternatives directory | LIVE—MAINTAIN | https://www.saashub.com/ai-dictation | https://www.saashub.com/manage/ai-dictation/edit | Ownership was verified August 2. The public page now uses claim-safe cross-platform copy, and the managed GitHub URL points to `writingmate/aidictation`; monitor the remaining catalog-approval state. | Verified badge and corrected public copy are live; dofollow not verified. |
| LibHunt | Open-source project catalog | LIVE—MAINTAIN | https://www.libhunt.com/r/aidictation | https://www.libhunt.com/repo/submit | Automatically approved August 2 with the canonical website, source, docs, MIT license label, and speech-to-text topics. A correction from `MIT` to `MIT License` is pending moderation so the OSI status renders correctly. | Public listing, website link, and source link verified; link attributes not separately verified. |
| freshcode.club | FLOSS release catalog | LIVE—MAINTAIN | https://freshcode.club/projects/aidictation | https://freshcode.club/submit | Published August 2 with newly authored CC-BY-SA-compatible copy, the canonical homepage, MITL license, platform tags, and the public source URL in the description. | Public listing and direct homepage link verified; link attributes not separately verified. |
| eudk/awesome-ai-tools | Community awesome list | LIVE—UPDATE | https://github.com/eudk/awesome-ai-tools | https://github.com/eudk/awesome-ai-tools/pull/490 | Cross-platform maintenance update submitted August 2, 2026. Track PR #490; do not add a duplicate. | Direct website link is visible in GitHub Markdown; no dofollow assertion. |

## Wave 1: free editorial and self-serve targets

The root MIT license and third-party notices are live on the default branch. Search each destination immediately before submission to avoid duplicates.

| Priority | Target | Type | Status | Form / start URL | Blocker / next action | Link evidence |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | AlternativeTo | Editorial alternatives directory | READY | https://alternativeto.net/faq/#add-a-new-application | New accounts must wait one week before adding an app. The logged-in `Suggest new application` flow asks for platforms, license, description, and tags. Use clean URLs; its FAQ discourages UTM parameters and links inside descriptions. | Dofollow not verified. |
| 2 | Future Tools | Curated AI directory | BLOCKED | https://futuretools.io/submit-a-tool | The current user browser policy explicitly blocks this domain and prohibits alternate submission routes. Revisit only if the owner changes that preference. | Dofollow not verified. |
| 3 | Uneed | Product launch directory | BLOCKED | https://www.uneed.best/submit-a-tool | The current user browser policy explicitly blocks this domain and prohibits alternate submission routes. Revisit only if the owner changes that preference. | Site markets backlink value; free-listing dofollow is unverified. Paid skip-the-wait-line dofollow is explicitly claimed in its changelog. |
| 5 | Product Hunt | Launch platform | READY | https://www.producthunt.com/launch | Prepare a maker profile, gallery, concise launch copy, and an authentic launch plan. Do not incentivize votes or fabricate traction. | Dofollow not verified; treat as discovery, not a backlink purchase. |
| 6 | MacUpdate | macOS software catalog | RESEARCH / ASSET | https://www.macupdate.com/help/submit-app | Follow the new-app guidelines. Provide a current signed/notarized macOS build, stable download URL, icon, and larger current screenshots. | Dofollow not verified. |
| 7 | Uptodown | Multi-platform app distribution | RESEARCH / ASSET | https://en.uptodown.com/developers-console | Create/verify the developer account and package ownership. Decide whether to sync the Google Play package or provide a signed publisher build. | Dofollow not verified. |
| 8 | SourceForge | Project hosting/distribution | READY | https://sourceforge.net/create/ | Create a project only if the team will maintain it. Prefer importing/mirroring the canonical Git repository and release files rather than creating a disconnected code history. | Dofollow not verified. |
| 9 | WinGet Community Repository | Windows package manager | RESEARCH / ASSET | https://learn.microsoft.com/en-us/windows/package-manager/package/repository | Prepare a stable versioned HTTPS installer URL, SHA-256 hash, silent install/uninstall behavior, and a manifest PR. | Package distribution target; dofollow not applicable. |
| 10 | There's An AI For That (TAAFT) | AI directory | BLOCKED | Paid/editorial page: https://theresanaiforthat.com/get-featured/ · former OSS form: https://tally.so/r/mRWbdK | The open-source/free Tally form currently says it is closed. Recheck for a reopened free route; do not pay or submit through another route without a budget decision. | No AI Dictation listing inspected; dofollow not verified. |

## Wave 2: distribution, company-profile, and longer-lead targets

| Priority | Target | Type | Status | Form / start URL | Blocker / next action | Link evidence |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | Microsoft Store | Windows app store | RESEARCH / ASSET | https://learn.microsoft.com/en-us/windows/apps/publish/get-started | Partner Center developer account, name reservation, certification fields, store assets, and an MSIX or supported MSI/EXE submission are required. A versioned HTTPS package URL is required for hosted MSI/EXE delivery. | Distribution target; dofollow not applicable. |
| 2 | Samsung Galaxy Store | Android app store | RESEARCH / ASSET | https://seller.samsungapps.com/ | Register a Samsung Seller Portal account and complete seller-status/identity requirements before submitting the signed Android build and store assets. | Distribution target; dofollow not applicable. |
| 3 | Aptoide | Android app store | RESEARCH / ASSET | https://connect.aptoide.com/ | Prove package ownership. Current docs say review requires an active Aptoide Connect subscription; a Google Play package can be synchronized, while manual distribution needs a signed APK and compliance details. | Distribution target; dofollow not applicable. |
| 4 | Crunchbase | Company database | RESEARCH / ASSET | https://support.crunchbase.com/hc/en-us/articles/115011823988-How-do-I-create-a-Crunchbase-profile | Search for Writingmate/AI Dictation first. Create or claim only the correct company profile; do not invent founding, funding, headcount, location, or founder data. | Profile presence is not a dofollow claim. |
| 5 | Peerlist Launchpad | Product launch platform | READY | https://peerlist.io/launchpad | Create a real maker profile and project, then use Launch. Launch slots are limited; avoid duplicate projects. | Dofollow not verified. |
| 6 | Setapp | Curated Mac/iOS distribution | RESEARCH / ASSET | https://setapp.com/developers | Editorial approval and technical review precede distribution. The macOS path requires Setapp integration, a compliant bundle, and 1280×800-or-larger 16:10 screenshots; contact the developer team first. | Distribution target; dofollow not evaluated. |
| 7 | Launching Next | Startup directory | PREPARED—HUMAN CHECK | https://www.launchingnext.com/submit/ | Duplicate search passed and the free form is filled with audited copy, nine relevant tags, `AI Dictation Team`, and `support@aidictation.com`; newsletter is off and funding/budget fields are blank. Complete the arithmetic Quick Check in the preserved Chrome tab and submit without choosing the optional $99 route. | Dofollow not verified; no listing exists until editorial approval. |
| 8 | AIxploria | AI directory | BLOCKED | https://www.aixploria.com/en/free-listing/ | The official page embeds Tally form `31KOPg`, but both the direct and embedded form currently return 404. Recheck the official page later; do not seek an unofficial route. | No AI Dictation listing inspected; dofollow not verified. |
| 9 | FOSShub | Free/open-source software hosting | PREPARED—HUMAN CHECK | https://www.fosshub.com/signup.html | Application is filled for a redirect to the existing service with unknown storage/bandwidth estimates. Complete the reCAPTCHA in the preserved in-app-browser tab, then request the free FOSShub account. | Dofollow not verified; no listing exists until approval. |
| 10 | Scoop Extras | Windows package manager | RESEARCH / ASSET | https://github.com/ScoopInstaller/Extras | Build and test a JSON manifest against a stable Windows asset. Include version, description, homepage, license, architecture, URL, SHA-256 hash, shortcuts/uninstaller, and update logic as applicable, then open a PR. | Package distribution target; dofollow not applicable. |
| 11 | Chocolatey Community Repository | Windows package manager | RESEARCH / ASSET | https://docs.chocolatey.org/en-us/create/create-packages/ | Create, test, publish, and continuously maintain a package. Confirm redistribution rights and stable installer/checksum behavior before moderation. | Package distribution target; dofollow not applicable. |
| 12 | FileHorse | Windows/macOS download catalog | BLOCKED | https://www.filehorse.com/submit/ | No duplicate was found, but policy preflight failed: the Windows 0.0.5 installer lacks Authenticode, the macOS 0.0.97 DMG container is unsigned despite its inner app being notarized, `/terms` is missing, no full mailing address is published, and both platform contact forms require reCAPTCHA. Fix signing and policy evidence before asking the owner to accept FileHorse's mirroring/asset grant. | Dofollow not verified. |
| 13 | SnapFiles | Windows download catalog | RESEARCH / ASSET | https://www.snapfiles.com/feedback/ | The public page directs developers to a Developer Account form and also offers `Suggest a software product`. Create/verify the developer account and provide a stable Windows build. | Dofollow not verified. |
| 14 | MajorGeeks | Curated Windows download catalog | BLOCKED | Closed form: https://www.majorgeeks.com/files/submitfile · contact instructions: https://www.majorgeeks.com/content/page/aboutcontact_us.html | The submission form currently says new file submissions are not accepted. Current contact guidance allows editorial email, but acceptance is highly selective. Recheck later rather than repeatedly emailing. | No listing; dofollow not verified. |
| 15 | FilePuma | Windows download catalog | RESEARCH / ASSET | https://www.filepuma.com/submit_program/ | Provide the current version, canonical website, and direct stable installer. The directory may link to or host submitted files and reserves editorial approval; review those terms first. | Dofollow not verified. |
| 16 | IzzyOnDroid | F-Droid-compatible Android repository | BLOCKED | Policy: https://izzyondroid.org/docs/general/AppInclusionPolicy/ · tracker entry point: https://izzyondroid.org/about/ | Requires FOSS licensing, public source, and an APK attached to a current tagged release; its new-app guidance also calls out a sub-30 MB APK check. The current Android release/dependency shape must be audited before filing in the linked Codeberg tracker. | Distribution target; dofollow not applicable. |
| 17 | Trustpilot | Review/company profile | RESEARCH / ASSET | https://business.trustpilot.com/signup | Search for an existing company page first. Claim/create only through the official business account and never seed, buy, gate, or incentivize reviews. | Profile presence is not a dofollow claim. |
| 18 | Open Hub | Open-source project index | READY | https://openhub.net/p/new | Free account/login required. Add the canonical repository, then verify repository import and project ownership. | Indexed project profile does not imply dofollow. |
| 19 | LocalAlternative | Local AI directory | SUBMITTED—REVIEW | https://www.localalternative.io/submit | Submitted August 2 after an exact duplicate search returned zero results. The accepted copy states that offline recognition is device-dependent, Apple offline mode requires macOS 14+ or iOS 17+, cloud cleanup can send text, and features vary by platform. The site confirmed receipt and estimated review within 48 hours. | No published listing yet; dofollow not verified. |
| 20 | Privacy Guides Tool Suggestions | Community editorial review | BLOCKED | https://discuss.privacyguides.net/c/site-development/tool-suggestions/9 | Not a promotional form. A good-faith recommendation must address threat model, data flows, funding, reproducibility, security posture, and independent evidence. Current mixed local/cloud behavior and missing independent audit make a promotional pitch inappropriate. | Editorial recommendation target; no backlink promise. |
| 21 | Microlaunch | Launch platform | READY | https://microlaunch.net/ | A free Basic Launch queue is available after login; the optional Pro launch is paid. Use only the free route unless a budget is explicitly approved. | Dofollow not verified. |
| 22 | Open Source Startups | Open-source directory | SUBMITTED—REVIEW | https://www.opensourcestartups.com/submit | Submitted August 2 with the canonical repository, website, AI & ML category, and claim-safe product copy. The site confirmed receipt and said the project would appear after approval. | No published listing yet; dofollow not verified. |
| 23 | NeuronFeed | AI startup directory | SUBMITTED—REVIEW | https://neuronfeed.com/submit/startup | Submitted August 2 with claim-safe copy and no optional location, founding, or traction claims. The site confirmed admin notification and review within 48 hours. | No published listing yet; published outbound links are currently nofollow. |
| 24 | OpenSaaSDirectory | Open-source SaaS directory | BLOCKED | https://opensaas.directory/submit-project | One carefully filled attempt returned to the form without a receipt, confirmation, or visible listing. Do not resubmit until the destination can confirm whether the first request was recorded. | No listing or receipt verified. |
| 25 | OpenAltFinder | Open-source alternatives directory | READY | https://openaltfinder.com/submit | Duplicate audit passed and the product fits as an open-source alternative to proprietary dictation tools, but Cloudflare Turnstile requires a human submission. | Published examples link to website and source; AI Dictation is not yet listed. |
| 27 | OpenAPK | Android FOSS catalog | SUBMITTED—REVIEW | https://github.com/mobilenetworkltd/openapk/issues/41 | Submitted through OpenAPK's official GitHub issue route after verifying the public MIT Android source, tagged APK release, checksums, package ID, and minimum Android version. Track issue #41; the optional reciprocal badge was not added. | No published OpenAPK listing yet; distribution target, so dofollow is not applicable. |
| 28 | Obtainium crowdsourced app directory | Android app directory | SUBMITTED—REVIEW | https://github.com/ImranR98/apps.obtainium.imranr.dev/pull/1570 | PR #1570 adds one app configuration for the official tagged Android APK; pre-commit validation passes. Track review and verify the generated page and release synchronization only after merge. | No generated AI Dictation page exists yet; distribution target, so no backlink claim is made. |
| 29 | Open Source Observer | Open-source project index | SUBMITTED—REVIEW | https://github.com/opensource-observer/oss-directory/pull/1140 | PR #1140 adds the canonical website and repository. The public `Validate PR` workflow passes; a separate maintainer-only artifact gate remains action-required. Track review without treating that gate as a code failure. | No indexed AI Dictation project page exists yet; link attributes cannot be evaluated before publication. |
| 30 | Internet Intro | Web discovery directory | SUBMITTED—RULE MISMATCH | https://internetintro.com/submit/ | A receipt was returned, but the submission preceded confirmation that the live rules exclude stores, sales pages, and overt campaigning. Expect editorial rejection; do not resubmit or contact the editor without a direct self-service withdrawal route. | No listing exists and no link is claimed; this receipt is not counted as a campaign win. |
| 31 | OpenLib | Open-source app library | READY | https://www.openlib.online/submit | An exact-name search returned no AI Dictation match. The owner must sign in with Google or GitHub, recheck for duplicates, and submit claim-safe source, license, platform, and install metadata. | No AI Dictation listing inspected; dofollow not verified. |
| 32 | Hi Cyou | SaaS and product directory | READY | https://hicyou.com/submit | No exact duplicate was found. The free daily queue requires owner login and Cloudflare Turnstile; the badge is optional and should not be added merely for fast-track or a claimed dofollow link. | No AI Dictation listing exists; free-listing link attributes are not verified. |
| 33 | Dir Hub | Indie app directory | READY | https://dirhub.io/submit | No exact duplicate was found. The owner must sign in with Google and use the free listing route; do not choose paid featured placement without a budget decision. | No AI Dictation listing exists; dofollow not verified. |
| 34 | Open Assistive | Assistive-technology catalog | BLOCKED | https://openassistive.org/add/ | The official intake API returned HTTP 500 even when tested with a known existing project, and final submission also requires reCAPTCHA. Retry only after the API works, then complete the human check without implying certification. | No submission, listing, or link is claimed. |
| 35 | Open Source Software Directory | Open-source application directory | SUBMITTED—REVIEW | https://opensourcesoftwaredirectory.com/about | A concise factual suggestion was sent from the connected owner mailbox to the editor address published on the live directory. Wait for editorial review, then verify any published copy and links. | The sent email is verified, but no AI Dictation listing is published or claimed; dofollow not verified. |

## Current submission receipts

### LocalAlternative — submitted August 2, 2026

- Name: `AI Dictation`
- Website: `https://aidictation.com`
- Repository: `https://github.com/writingmate/aidictation`
- Tagline: `Cross-platform voice-to-text with offline recognition on supported devices`
- Contact: `support@aidictation.com`
- Description: `AI Dictation is a cross-platform voice-to-text app with MIT-licensed native client source. It provides offline speech recognition on supported devices and optional cloud transcription and cleanup. On Apple platforms, offline recognition requires macOS 14+ or iOS 17+. Cloud cleanup can still send transcript text when enabled, so users who need an on-device workflow must disable cloud features. Feature availability varies by platform.`
- Receipt: `Thank you! Your tool has been submitted for review.` The page said review would occur within 48 hours.

### SaaSHub — verified and corrected August 2, 2026

The domain-email verification link was opened and SaaSHub confirmed ownership.
The public page now identifies AI Dictation as open source and uses the
claim-safe tagline and description. The managed GitHub URL was corrected from
`writingmate/whispermate` to `writingmate/aidictation`; the App Store and Google
Play URLs were also added. The page remains in SaaSHub's catalog-approval queue.

### LibHunt — live August 2, 2026

- Listing: https://www.libhunt.com/r/aidictation
- Receipt: `Thanks for your submission! It's been approved automatically.`
- Verified fields: canonical website, source repository, docs, Swift, MIT,
  self-hosted/standalone status, and eight relevant topics.
- Follow-up: a moderated edit requests the canonical `MIT License` label because
  the initial free-text `MIT` value rendered an incorrect OSI-status sentence.

### freshcode.club — live August 2, 2026

- Listing: https://freshcode.club/projects/aidictation
- Receipt: `Submitted — Project and release information have been updated.`
- The listing has the canonical homepage, MITL license, desktop/mobile/platform
  tags, and newly authored copy that was explicitly submitted under CC-BY-SA.

### Open Source Startups — submitted August 2, 2026

The site confirmed `Submission received!` and said AI Dictation would appear in
the directory after review. The submission used the canonical repository and
website, the `AI & ML` category, and claim-safe cross-platform copy.

### NeuronFeed — submitted August 2, 2026

The site confirmed `Submission received — admin notification sent` and a
48-hour human review. Optional headquarters, founding-year, funding, and
traction fields were left blank rather than inferred.

### OpenSaaSDirectory — attempted, no receipt

The form was filled once with the canonical repository and claim-safe copy. It
returned to its initial state without a confirmation, visible error, or listing,
so this tracker does not count it as submitted and prohibits a blind retry.

### OpenAPK — submitted August 2, 2026

- Submission: https://github.com/mobilenetworkltd/openapk/issues/41
- Verified release: `android-v0.0.32`, including its public APK and checksums.
- Verified Android metadata: package `com.aidictation.app`, minimum SDK 26, and
  MIT-licensed public source.
- OpenAPK's reciprocal website badge is optional and was not added.

### Obtainium — PR submitted August 2, 2026

- Submission: https://github.com/ImranR98/apps.obtainium.imranr.dev/pull/1570
- Scope: one configuration file for package `com.aidictation.app`, using the
  official Android release feed, a single APK filter, numeric version extraction,
  and the official icon.
- Validation: pre-commit CI passes. The PR is open and mergeable; no generated
  directory page is claimed until maintainers merge it.

### Open Source Observer — PR submitted August 2, 2026

- Submission: https://github.com/opensource-observer/oss-directory/pull/1140
- Scope: one project record containing the canonical website and repository.
- Validation: the upstream `Validate PR` workflow passes. The additional
  `validate` state is a maintainer-only artifact gate marked action-required,
  not a failing schema or contribution check. No indexed project page is
  claimed before merge.

### Internet Intro — receipt recorded with rule mismatch August 2, 2026

The site acknowledged the link and said a human would review it. That submission
was made just before the live rules were confirmed to exclude stores, sales
pages, and overt campaigning. There is no self-service withdrawal control, so
the tracker expects editorial rejection and prohibits a second submission or
unsolicited follow-up. This is not counted as a successful placement, and no
listing or backlink is claimed.

### Open Source Software Directory — submitted August 2, 2026

The live about page invites readers to suggest missing open-source applications
by emailing `info@opensourcesoftwaredirectory.com`. A concise suggestion was
sent from the connected owner mailbox with the canonical
website and repository, current platform scope, MIT client-source statement,
offline/cloud limitation, project affiliation, and AI-assistance disclosure.
The send operation returned a Gmail `SENT` record. Editorial acceptance and a
published listing remain unverified, so no placement or backlink is claimed.

### FOSShub — prepared, not submitted

The preserved form uses `AI Dictation Team`, `support@aidictation.com`,
`https://aidictation.com`, unknown storage and bandwidth estimates, and the
“redirect it to my existing service” option. The required reCAPTCHA remains
unresolved, so no application receipt exists.

## Deferred and rejected targets

| Target | Status | Form / information URL | Reason to defer or reject | Link evidence |
| --- | --- | --- | --- | --- |
| F-Droid | BLOCKED | https://gitlab.com/fdroid/rfp/-/issues/new | Current Android delivery depends on Google Play asset delivery. Resolve the reproducible FOSS build/distribution path before opening an RFP. | Distribution target; dofollow not applicable. |
| OpenSourceFest | BLOCKED | https://opensourcefest.org/submit | Final endpoint verification found that the live form posts to the placeholder address `your-email@opensourcefest.org`. Its FormSubmit activation screen therefore does not prove delivery to the directory; no submission is recorded. | No listing or valid receipt; dofollow not evaluated. |
| ListSOpenSource | BLOCKED | https://listsopensource.com/submit/ | The current domain does not resolve in DNS. Cached crawler content is not a safe submission route; recheck the live domain later rather than opening a speculative issue. | No live submission or listing is claimed. |
| OPEN_SRC.ME | BLOCKED | https://opensrc.me/submit | Cached content described a free basic listing, but the live site currently fails its TLS handshake. Recheck only after HTTPS works; do not submit through cached or alternate routes. | No live submission or listing is claimed. |
| osssoftware.org | DEFER—PAID | https://osssoftware.org/ | The current visible submission choices are paid, starting at $299, and no clear free route was found. Require an explicit budget decision before proceeding. | Paid placement and link claims were not independently verified; no listing is claimed. |
| The App Fair Project | NO FIT | https://appfair.org/marketplace/distribution/ | Current distribution requirements include GPL-2.0-or-later licensing, no monetization, FOSS dependencies, and App Fair-specific cross-platform and metadata constraints that the current product does not meet. | Distribution target; dofollow not applicable. |
| tools.us.org | AVOID | https://tools.us.org/ | Placeholder content, contradictory proprietary/open-source categorization, and weak editorial signals make this a low-trust target. Do not submit. | No submission or listing is planned. |
| Homebrew Cask | BLOCKED | https://docs.brew.sh/Adding-Software-to-Homebrew | The project does not currently meet Homebrew's documented popularity-policy thresholds captured in the research. Recheck later; do not manufacture stars, forks, or watchers. | Package distribution target; dofollow not applicable. |
| G2 | NO FIT | https://sell.g2.com/ | Research found the current consumer app outside the intended B2B software-review fit. Revisit only if a real business/team product emerges. | No listing; dofollow not verified. |
| Capterra | NO FIT | https://www.capterra.com/vendors/sign-up | Research found the current consumer app outside the intended B2B software-directory fit. | No listing; dofollow not verified. |
| Flathub | NO FIT | https://docs.flathub.org/docs/for-app-authors/submission/ | There is no Linux app/package to submit. | Distribution target; dofollow not applicable. |
| Fazier | DEFER—RECIPROCAL | https://fazier.com/submit | The free route requires a reciprocal homepage/footer backlink. Do not alter the product site for a directory requirement without an explicit SEO/product decision. Paid routes advertise backlink benefits but are out of scope. | Paid dofollow is a directory claim; no AI Dictation listing inspected. |
| OpenAlternative | DEFER—PAID | https://openalternative.co/submit | Login/submission route exists, but research found no suitable free publication path. Approved tools also populate its `piotrkulpinski/open-source-alternatives` GitHub mirror, so do not open a separate mirror PR. | Paid-package link claims not independently verified. |
| Toolify | DEFER—PAID | https://www.toolify.ai/payment?type=submit | Submission routes to payment. Require an explicit budget decision. | Paid link attributes not verified. |
| Futurepedia | DEFER—PAID | https://www.futurepedia.io/submit-tool | Current submission page requires a paid listing option. Require an explicit budget decision. | Paid link attributes not verified. |
| BetaList | DEFER—PAID | https://betalist.com/submit | Research found no suitable free route for this campaign. Require a budget decision. | Paid link attributes not verified. |
| That AI Collection | DEFER—LOW TRUST | https://thataicollection.com/en/categories/translation-and-transcript | The directory and GitHub mirror use redirect/tracking links. Lower priority than direct-link editorial targets. | Redirect/tracking behavior observed; dofollow not claimed. |
| forecho/awesome-voice-input-methods | AVOID | https://github.com/forecho/awesome-voice-input-methods | Low-activity, referral-heavy list found during research. The expected value and editorial trust are too low. | No submission planned. |

## Operating workflow

For every manual submission:

1. Search for `AI Dictation`, `AIDictation`, `aidictation.com`, and the package/application ID.
2. Confirm the root MIT license and third-party notices remain live, then use the copy in `submission-pack.md`.
3. Save a screenshot or receipt of the completed form.
4. Add the date, owner, submitted copy version, and result to the CSV/tracker.
5. When a page goes live, record its exact URL and verify:
   - page is reachable without login;
   - canonical URL and product facts are correct;
   - search indexing separately, if that is a campaign goal;
   - outbound URL destination;
   - `rel` attributes and redirects separately, if link quality matters.
6. Mark a link `dofollow verified` only after inspecting the published HTML/redirect chain. A directory's sales claim belongs in notes, not in the verified field.

## Current cross-target blockers

- Cross-platform hero and current Windows/macOS store screenshots are missing.
- Several distribution targets need stable versioned package URLs, checksums, signing/notarization, and owner accounts.
- FileHorse specifically requires a trusted Windows Authenticode signature, a signed macOS DMG container, a valid public mailing address, and applicable terms/EULA; two human reCAPTCHAs remain after those fixes.
- A tagged Android APK now exists, and OpenAPK and Obtainium submissions are
  pending. F-Droid and other strict FOSS catalogs still require a reproducible
  non-Google delivery path and a dependency audit.
- No budget is authorized for paid listings, expedited review, reciprocal-link placement, or directory packages.
- The current user browser policy explicitly blocks Future Tools, Uneed, and
  Tally. It also blocked APKPure's official update route in this run. Do not
  retry those domains or use an alternate browser/submission path unless the
  owner changes that preference.
- No external submission should quote website metrics, discounts, language counts, compliance labels, rankings, or comparative performance without dated primary evidence.

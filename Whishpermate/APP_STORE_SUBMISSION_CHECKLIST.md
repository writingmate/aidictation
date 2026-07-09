# WhisperMate iOS - App Store Submission Checklist

## 📋 Pre-Submission Checklist

### 1. Apple Developer Account Setup
- [ ] Apple Developer Program membership active ($99/year)
- [ ] Team ID: G7DJ6P37KU verified
- [ ] Payment and financial info set up

### 2. App Store Connect Setup
- [ ] App created in App Store Connect
  - **Bundle ID**: `com.whispermate.ios`
  - **App Name**: WhisperMate
  - **SKU**: whispermate-ios (or similar unique identifier)
- [ ] Keyboard Extension registered
  - **Bundle ID**: `com.whispermate.ios.keyboard`

### 3. Certificates & Provisioning
- [ ] iOS Distribution Certificate created
- [ ] App Store provisioning profile for main app
- [ ] App Store provisioning profile for keyboard extension
- [ ] Profiles downloaded and installed in Xcode

### 4. App Information
- [ ] App name: **WhisperMate** (confirmed available)
- [ ] Subtitle: **Voice-to-text keyboard for iOS**
- [ ] Category: **Productivity** (Primary), **Utilities** (Secondary)
- [ ] Age rating: **4+** (completed self-assessment)
- [ ] Copyright: **© 2024-2025 WhisperMate**

### 5. Metadata & Content
- [ ] App description written (from APP_STORE_METADATA.md)
- [ ] Keywords set: `voice to text, speech recognition, dictation, voice keyboard, transcription, voice input, speech to text`
- [ ] Promotional text added (170 char)
- [ ] What's New in 0.0.92 written
- [ ] Support URL: https://github.com/writingmate/aidictation/blob/codex/ios-app-review-fixes/SUPPORT.md
- [ ] Marketing URL: https://github.com/writingmate/aidictation
- [ ] Privacy Policy URL: https://github.com/writingmate/aidictation/blob/codex/ios-app-review-fixes/Whishpermate/PRIVACY_POLICY.md

### 6. Visual Assets
**Screenshots (iPhone 6.7" - Required)**
- [ ] 1. Welcome/Onboarding ✅ CAPTURED
- [ ] 2. Recording Interface 🔴 NEEDED
- [ ] 3. Transcription Result 🔴 NEEDED
- [ ] 4. Keyboard Extension 🔴 NEEDED
- [ ] 5. Share Menu 🔴 NEEDED

**App Icon**
- [ ] 1024x1024px app icon (no transparency, no alpha channel)
- [ ] All required icon sizes generated in Assets.xcassets

**App Preview Video (Optional)**
- [ ] 15-30 second video showing app in action
- [ ] Proper resolution for each device size

### 7. Privacy & Compliance
- [ ] Privacy policy written ✅ (PRIVACY_POLICY.md)
- [ ] Privacy policy hosted at public URL 🔴 NEEDED
- [ ] Privacy Nutrition Label completed in App Store Connect
  - **Data Types Collected**: Audio (for transcription only), email address, account identifier, subscription status, usage data, diagnostics
  - **Data Use**: App Functionality
  - **Data Linked to User**: Yes for account, subscription, and usage data when signed in
  - **Data Used to Track You**: No
- [ ] Account deletion verified on a physical iPhone
- [ ] Account deletion screen recording attached in App Review Information Notes
- [ ] Export Compliance: No (if not using encryption beyond standard iOS)

### 8. App Review Information
- [ ] Contact information provided
  - First name: Artsiom
  - Last name: Vysotski
  - Email: support@whispermate.ai
  - Phone: [Your phone]
- [ ] Demo account info provided for account deletion review
- [ ] Notes for reviewer written (see APP_STORE_METADATA.md)
- [ ] Test instructions provided

### 9. Build & Upload
- [ ] Version: 0.0.92
- [ ] Build number: 101
- [ ] App archived with Release configuration
- [ ] Code signing configured correctly
- [ ] No debug symbols or test code included
- [ ] All third-party frameworks included
- [ ] Entitlements correct:
  - [ ] Microphone access
  - [ ] Keyboard extension
  - [ ] App groups (if needed)

### 10. Testing
**Functional Testing**
- [ ] App launches without crashes
- [ ] Onboarding flow works correctly
- [ ] Microphone permission request appears
- [ ] Voice recording works
- [ ] Transcription completes successfully
- [ ] Keyboard extension installs and activates
- [ ] Keyboard mic button functional
- [ ] Share menu works
- [ ] All UI elements display correctly
- [ ] No memory leaks or performance issues

**Device Testing**
- [ ] iPhone (multiple models tested)
- [ ] iPad (if supported)
- [ ] Various iOS versions (17.0+)
- [ ] Different network conditions
- [ ] Low memory conditions

**Accessibility**
- [ ] VoiceOver compatibility
- [ ] Dynamic Type support
- [ ] Sufficient color contrast
- [ ] Labeled UI elements

### 11. TestFlight (Recommended)
- [ ] App uploaded to TestFlight
- [ ] Internal testing completed
- [ ] Beta testing group invited
- [ ] Feedback collected and addressed
- [ ] Known issues documented

### 12. Legal & Business
- [ ] Terms of Service written (optional but recommended)
- [ ] Privacy policy legally reviewed
- [ ] EULA set (default or custom)
- [ ] Pricing set (Free or Paid)
- [ ] In-app purchases configured (if any)
- [ ] Subscriptions set up (if applicable)

---

## 🚀 Submission Steps

### Step 1: Finalize Assets
1. Complete remaining screenshots (4 more needed)
2. Verify privacy policy URL is live
3. Verify all URLs are live and accessible

### Step 2: Create App in App Store Connect
1. Go to https://appstoreconnect.apple.com
2. Click "+" to create new app
3. Fill in basic information:
   - Platform: iOS
   - Name: WhisperMate
   - Primary Language: English (U.S.)
   - Bundle ID: com.whispermate.ios
   - SKU: whispermate-ios
   - User Access: Full Access

### Step 3: Configure App Information
1. Navigate to "App Information" section
2. Set category, age rating, etc.
3. Add privacy policy URL
4. Configure app privacy details

### Step 4: Upload Build
```bash
# Archive the app
xcodebuild -scheme WhisperMateIOS \
  -destination 'generic/platform=iOS' \
  -archivePath "WhisperMate-iOS-v0.0.92-build-101.xcarchive" \
  archive \
  -allowProvisioningUpdates

# Export for App Store
xcodebuild -exportArchive \
  -archivePath "WhisperMate-iOS-v0.0.92-build-101.xcarchive" \
  -exportPath "WhisperMate-iOS-Export" \
  -exportOptionsPlist ExportOptions.plist

# Upload to App Store Connect (via Xcode or Transporter app)
```

### Step 5: Prepare for Release
1. Select the uploaded build in App Store Connect
2. Add screenshots and metadata
3. Complete "What's New" section
4. Set release options:
   - Manual release
   - Automatic release after approval
   - Scheduled release
5. Configure pricing and availability

### Step 6: Submit for Review
1. Review all information one final time
2. Click "Submit for Review"
3. Wait for review status updates (check email)
4. Respond promptly to any App Review messages

### Step 7: After Approval
1. Monitor for crashes or issues (via App Analytics)
2. Respond to user reviews
3. Plan updates and improvements
4. Market the app on social media, website, etc.

---

## 🆘 Troubleshooting Common Issues

### Issue: "No profiles found"
**Solution**: Create App Store provisioning profiles in Apple Developer portal, download, and install in Xcode.

### Issue: "Build rejected - crashes on launch"
**Solution**: Test thoroughly on actual devices (not just simulator), check for missing frameworks or resources.

### Issue: "Privacy policy URL not accessible"
**Solution**: Ensure privacy policy is hosted at a public URL that's accessible without login.

### Issue: "Keyboard extension not working"
**Solution**: Verify entitlements, app groups, and proper bundle ID configuration.

### Issue: "Binary rejected due to metadata issues"
**Solution**: Review guideline violations in rejection email, update metadata, resubmit (no new build needed).

---

## ⏱️ Estimated Timeline

| Phase | Duration | Notes |
|-------|----------|-------|
| Asset Preparation | 2-4 hours | Screenshots, icons, privacy policy |
| App Store Connect Setup | 1-2 hours | First-time setup |
| Build & Upload | 1-2 hours | Archive, sign, upload |
| Metadata Entry | 1-2 hours | Descriptions, keywords, etc. |
| **Total Prep Time** | **5-10 hours** | |
| **Initial Review** | **24-48 hours** | Apple's review time |
| **Follow-up (if rejected)** | **24 hours** | Re-review time |

---

## 📞 Support Resources

- **Apple Developer Forums**: https://developer.apple.com/forums/
- **App Store Connect Help**: https://help.apple.com/app-store-connect/
- **App Review Guidelines**: https://developer.apple.com/app-store/review/guidelines/
- **Technical Support**: https://developer.apple.com/support/

---

## ✅ Current Status: v0.0.92 build 101

**Completed:**
- ✅ macOS version released
- ✅ iOS app builds successfully
- ✅ Metadata written
- ✅ Privacy policy drafted
- ✅ 1 screenshot captured

**Remaining:**
- 🔴 4+ screenshots needed
- 🔴 Privacy policy needs web hosting
- 🔴 App Store provisioning profiles
- 🔴 TestFlight distribution (optional)
- 🔴 Final App Store submission

**Next Immediate Steps:**
1. Capture remaining 4 screenshots
2. Verify privacy policy URL is live
3. Create provisioning profiles in Apple Developer portal
4. Create app in App Store Connect
5. Archive and upload build

---

*Last Updated: November 5, 2025*
*Version: 0.0.92 (101)*

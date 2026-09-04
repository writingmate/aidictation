# Android: Google sign-in

"Continue with Google" in Settings › Account is the only way to sign in to the
Android app; the web sign-in button was removed. It has two modes.

## Hosted flow (default, no extra setup)

The auth API at `aidictation.com` already runs Google OAuth: its
`/auth/v1/authorize?provider=google` endpoint redirects to Google with the existing
writingmate client and finishes at `/auth/v1/callback`. The app opens that URL in the
browser with `redirect_to=aidictation://auth-callback`, so the session lands in the same
deep-link handler the web sign-in uses (`AuthRepository.handleAuthCallback`). Nothing
needs configuring for this mode; the button shows whenever auth is configured.

## Native flow (optional)

With `GOOGLE_WEB_CLIENT_ID` set, the app instead uses Android's Credential Manager:

1. It asks for a Google ID token, passing the Web (server) OAuth client ID and the
   SHA-256 of a fresh random nonce.
2. Google shows the account picker and returns an ID token whose `nonce` claim is that
   hash.
3. The app posts `{provider: "google", id_token, nonce}` (the raw nonce) to
   `${SUPABASE_URL}/auth/v1/token?grant_type=id_token` with the anon `apikey` header,
   Supabase Auth's ID-token grant, and stores the returned session.

The auth API implements this grant (speak-it-fast `functions/auth/v1/token.ts`,
`grant_type=id_token`): it verifies the ID token with Google's tokeninfo endpoint,
requires `aud` to be the web client and `nonce` to be the SHA-256 of the raw nonce, then
signs the user in or creates the account exactly like the browser callback does.

Setup (done 2026-09-03 in Google Cloud project `aidictation-506107`):

1. `GOOGLE_WEB_CLIENT_ID` = the existing **Web application** client
   `553212855846-amcf79495lvti8fnqr1t7vggophr7k4s.apps.googleusercontent.com`; it is set
   in `local.properties` locally and in the `pull-request` and `release` GitHub
   environments.
2. **Android** OAuth clients for package `com.aidictation.app`, one per signing key:
   the debug keystore (`~/.android/debug.keystore`) and the release keystore. Play App
   Signing re-signs store builds with its own key, so its SHA-1 (Play Console › Setup ›
   App signing) needs a third Android client before the Play build can sign in.
3. The auth backend's Google provider already trusts that web client (it is the one the
   hosted flow uses).

## Code

- `AuthRepository.signInWithGoogle`, `openHostedGoogleSignIn`, `exchangeGoogleIdToken`
- `SubscriptionRepository.signInWithGoogle`, `MainViewModel.signInWithGoogle`
- `GoogleSignInButton` in `SettingsScreen.kt`, the G mark in `ic_google_g.xml`
- Dependencies: `androidx.credentials:credentials`,
  `androidx.credentials:credentials-play-services-auth`,
  `com.google.android.libraries.identity.googleid:googleid`

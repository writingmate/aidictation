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

**Do not set the client ID until the auth API implements that grant.** As of this
writing `aidictation.com/auth/v1/token?grant_type=id_token` answers with the password
grant's "Email and password are required", so the native exchange would fail. The
underlying Supabase project (`labs-api.writingmate.ai`) does support it, so proxying
that route is enough.

Setup for the native mode, when the backend is ready:

1. Google Cloud › Credentials (the writingmate project): reuse the existing **Web
   application** client as `GOOGLE_WEB_CLIENT_ID`, and add an **Android** client for
   package `com.aidictation.app` per signing key in use (debug SHA-1, release SHA-1,
   Play App Signing's SHA-1). Without a matching Android client Google refuses to
   issue the token.
2. Auth backend: the Web client ID must be among the provider's authorised client IDs.
3. Put `GOOGLE_WEB_CLIENT_ID` in `local.properties` and in the `pull-request` and
   `release` GitHub environments.

## Code

- `AuthRepository.signInWithGoogle`, `openHostedGoogleSignIn`, `exchangeGoogleIdToken`
- `SubscriptionRepository.signInWithGoogle`, `MainViewModel.signInWithGoogle`
- `GoogleSignInButton` in `SettingsScreen.kt`, the G mark in `ic_google_g.xml`
- Dependencies: `androidx.credentials:credentials`,
  `androidx.credentials:credentials-play-services-auth`,
  `com.google.android.libraries.identity.googleid:googleid`

# Android: native Google sign-in

The Android app offers "Continue with Google" in Settings › Account next to the
existing web sign-in. It uses Android's Credential Manager to get a Google ID token on
the device and trades it for an app session at the auth API, so no browser round trip.

## How it works

1. The app asks Credential Manager for a Google ID token, passing the Web (server)
   OAuth client ID and the SHA-256 of a fresh random nonce.
2. Google shows the account picker and returns an ID token whose `nonce` claim is that
   hash.
3. The app posts `{provider: "google", id_token, nonce}` (the raw nonce) to
   `${SUPABASE_URL}/auth/v1/token?grant_type=id_token` with the anon `apikey` header.
   This is Supabase Auth's ID-token grant.
4. The response's `access_token` and `refresh_token` are stored in the same encrypted
   preferences the web sign-in uses; the rest of the app is unchanged.

Dismissing the picker does nothing. Any other failure sets `AuthState.error` and shows
a toast.

## One-time setup

1. **Google Cloud** › APIs & Services › Credentials:
   - Create an OAuth client of type **Web application**. Its client ID is the
     `GOOGLE_WEB_CLIENT_ID`. Add the auth API's callback URL as an authorised redirect
     URI (Supabase: `https://<project>.supabase.co/auth/v1/callback`).
   - Create an OAuth client of type **Android** for package `com.aidictation.app` for
     each signing key in use: the debug keystore's SHA-1, the release keystore's SHA-1,
     and Play App Signing's SHA-1 (Play Console › App integrity). Without a matching
     Android client Google refuses to issue the token.
2. **Auth backend** (Supabase › Authentication › Providers › Google): enable it, set the
   Web client ID and secret, and add the same Web client ID under "Authorized Client
   IDs". If the API at `aidictation.com` proxies Supabase Auth, it must forward the
   `grant_type=id_token` request unchanged.
3. **Build configuration**: put `GOOGLE_WEB_CLIENT_ID=<web client id>` in
   `local.properties`, and add the `GOOGLE_WEB_CLIENT_ID` secret to the GitHub
   `pull-request` and `release` environments so CI builds carry it. A blank value hides
   the button.

## Code

- `AuthRepository.signInWithGoogle` and `exchangeGoogleIdToken`
- `SubscriptionRepository.signInWithGoogle`, `MainViewModel.signInWithGoogle`
- `GoogleSignInButton` in `SettingsScreen.kt`, the G mark in `ic_google_g.xml`
- Dependencies: `androidx.credentials:credentials`,
  `androidx.credentials:credentials-play-services-auth`,
  `com.google.android.libraries.identity.googleid:googleid`

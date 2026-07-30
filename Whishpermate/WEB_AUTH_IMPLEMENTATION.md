# Web Authentication Implementation Guide

This document describes the web-based authentication page at `https://aidictation.com/auth` that redirects back to the AI Dictation macOS app.

## Overview

WhisperMate uses **Implicit Flow** for web-based authentication where:
1. The native app opens the web page in a browser
2. User authenticates with email/password on the web page
3. Web page redirects back to the app with tokens in URL hash fragment
4. App extracts tokens and establishes session

## Authentication Flow

```
┌─────────────┐                    ┌──────────────────┐                    ┌──────────────┐
│ Native App  │                    │  Web Auth Page   │                    │   Supabase   │
└──────┬──────┘                    └────────┬─────────┘                    └──────┬───────┘
       │                                    │                                      │
       │ 1. Open browser with redirect_to  │                                      │
       ├───────────────────────────────────>│                                      │
       │                                    │                                      │
       │                                    │ 2. User enters email/password        │
       │                                    │                                      │
       │                                    │ 3. signInWithPassword()              │
       │                                    ├─────────────────────────────────────>│
       │                                    │                                      │
       │                                    │ 4. Session tokens                    │
       │                                    │<─────────────────────────────────────┤
       │                                    │                                      │
       │ 5. Redirect with tokens in hash    │                                      │
       │<───────────────────────────────────┤                                      │
       │                                    │                                      │
       │ 6. Extract tokens & establish      │                                      │
       │    session                         │                                      │
       │                                    │                                      │
```

## Web Page Implementation

### 1. URL Parameters

Your web page receives:
```
https://aidictation.com/auth?redirect_to=whispermate://auth-callback
```

Extract the `redirect_to` parameter:
```javascript
const params = new URLSearchParams(window.location.search);
const redirectTo = params.get('redirect_to') || 'whispermate://auth-callback';
```

### 2. Initialize Supabase Client

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://aidictation.com',
  'YOUR_SUPABASE_ANON_KEY'
)
```

### 3. Handle Sign Up

```javascript
async function handleSignUp(email, password) {
  const { data, error } = await supabase.auth.signUp({
    email: email,
    password: password
  })

  if (error) {
    console.error('Sign up error:', error.message)
    showError(error.message)
    return
  }

  // If email confirmation is disabled in Supabase settings
  if (data.session) {
    redirectToApp(data.session)
  } else {
    // If email confirmation is required
    showMessage('Check your email to confirm your account')
  }
}
```

### 4. Handle Sign In

```javascript
async function handleSignIn(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email,
    password: password
  })

  if (error) {
    console.error('Sign in error:', error.message)
    showError(error.message)
    return
  }

  redirectToApp(data.session)
}
```

### 5. Redirect Back to App

**CRITICAL**: Use hash fragment (`#`), not query parameters (`?`)

```javascript
function redirectToApp(session) {
  // Build redirect URL with tokens in hash fragment
  const url = `${redirectTo}#` +
    `access_token=${session.access_token}&` +
    `refresh_token=${session.refresh_token}&` +
    `token_type=${session.token_type || 'bearer'}&` +
    `expires_in=${session.expires_in}`

  // Redirect to native app
  window.location.href = url
}
```

### Example Complete Implementation

```html
<!DOCTYPE html>
<html>
<head>
  <title>WhisperMate Authentication</title>
  <script src="https://unpkg.com/@supabase/supabase-js@2"></script>
</head>
<body>
  <div id="auth-container">
    <h1>Sign In to WhisperMate</h1>

    <form id="auth-form">
      <input type="email" id="email" placeholder="Email" required>
      <input type="password" id="password" placeholder="Password" required>
      <button type="submit" id="signin-btn">Sign In</button>
      <button type="button" id="signup-btn">Sign Up</button>
    </form>

    <div id="message"></div>
  </div>

  <script>
    // Initialize Supabase
    const supabase = supabase.createClient(
      'https://aidictation.com',
      'YOUR_SUPABASE_ANON_KEY'
    )

    // Get redirect URL
    const params = new URLSearchParams(window.location.search)
    const redirectTo = params.get('redirect_to') || 'whispermate://auth-callback'

    // Handle form submission
    document.getElementById('signin-btn').addEventListener('click', async (e) => {
      e.preventDefault()
      await handleSignIn()
    })

    document.getElementById('signup-btn').addEventListener('click', async (e) => {
      e.preventDefault()
      await handleSignUp()
    })

    async function handleSignIn() {
      const email = document.getElementById('email').value
      const password = document.getElementById('password').value

      const { data, error } = await supabase.auth.signInWithPassword({
        email,
        password
      })

      if (error) {
        showMessage(error.message, 'error')
        return
      }

      redirectToApp(data.session)
    }

    async function handleSignUp() {
      const email = document.getElementById('email').value
      const password = document.getElementById('password').value

      const { data, error } = await supabase.auth.signUp({
        email,
        password
      })

      if (error) {
        showMessage(error.message, 'error')
        return
      }

      if (data.session) {
        redirectToApp(data.session)
      } else {
        showMessage('Check your email to confirm your account', 'info')
      }
    }

    function redirectToApp(session) {
      const url = `${redirectTo}#` +
        `access_token=${session.access_token}&` +
        `refresh_token=${session.refresh_token}&` +
        `token_type=bearer&` +
        `expires_in=${session.expires_in}`

      window.location.href = url
    }

    function showMessage(msg, type) {
      const messageDiv = document.getElementById('message')
      messageDiv.textContent = msg
      messageDiv.className = type
    }
  </script>
</body>
</html>
```

## Redirect URL Format

The web page MUST redirect using this exact format:

```
whispermate://auth-callback#access_token=eyJh...&refresh_token=v1:...&token_type=bearer&expires_in=3600
```

**Important:**
- Use hash fragment (`#`), NOT query parameters (`?`)
- All parameters are required: `access_token`, `refresh_token`, `token_type`, `expires_in`
- The native app will extract these and establish the session

## Supabase Configuration

### 1. Add Redirect URL

In your Supabase dashboard:
1. Go to Authentication → URL Configuration
2. Add to "Redirect URLs":
   ```
   whispermate://auth-callback
   ```

### 2. Email Confirmation (Optional)

If you want users to sign in immediately without email confirmation:
1. Go to Authentication → Settings
2. Disable "Enable email confirmations"

## Security Considerations

### Implicit Flow Security

The implicit flow passes tokens in URL fragments. This is acceptable for desktop apps because:

- **Hash fragments are not sent to servers** - They remain in the browser/app
- **macOS app sandboxing** - Apps are isolated from each other
- **Token expiration** - Access tokens expire (typically 1 hour)
- **Refresh token rotation** - Supabase rotates refresh tokens automatically
- **Native app validation** - App validates callback URL scheme and host

### Best Practices

1. **Use HTTPS** - Your web page must use HTTPS
2. **Validate input** - Sanitize email/password inputs
3. **Show loading states** - Prevent multiple submissions
4. **Handle errors gracefully** - Show clear error messages
5. **Test redirect** - Verify the custom URL scheme works

## Testing

### Test Sign Up Flow
```bash
# Open in browser:
open "https://aidictation.com/auth?redirect_to=whispermate://auth-callback"

# Expected:
# 1. Form appears
# 2. Enter email/password and click "Sign Up"
# 3. Browser redirects to whispermate://auth-callback#access_token=...
# 4. WhisperMate app launches and shows authenticated state
```

### Test Sign In Flow
```bash
# Same as above, but use "Sign In" button for existing users
```

### Debug Callback URL
```javascript
// Add before redirect to see the full URL:
console.log('Redirecting to:', url);
```

## Troubleshooting

### "Invalid redirect URL" error
- Verify `whispermate://auth-callback` is in Supabase Redirect URLs list
- Check URL is exactly matching (no trailing slash)

### App doesn't open after authentication
- Verify custom URL scheme is registered in WhisperMate's Info.plist
- Test URL scheme: `open "whispermate://auth-callback#test=1"`

### "Session is missing" error
- Verify you're using hash fragment (`#`) not query params (`?`)
- Check all required parameters are included in redirect URL
- Verify tokens are valid and not expired

### Email confirmation required
- Either complete email confirmation flow
- Or disable email confirmations in Supabase settings for faster testing

## Native App Configuration (Reference)

The native app is configured to handle the callback:

**Info.plist** - URL scheme registration:
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>whispermate</string>
        </array>
    </dict>
</array>
```

**WhispermateApp.swift** - URL handling:
```swift
.onOpenURL { url in
    if url.scheme == "whispermate" && url.host == "auth-callback" {
        Task { await authManager.handleAuthCallback(url: url) }
    }
}
```

**AuthManager.swift** - Token extraction:
```swift
public func handleAuthCallback(url: URL) async {
    try await supabase.client.auth.session(from: url)
    await refreshUser()
}
```

## Contact

For questions about the native app implementation, contact the WhisperMate development team.

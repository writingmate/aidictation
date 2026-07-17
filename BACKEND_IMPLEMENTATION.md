# WhisperMate Backend Implementation Guide

> **Legacy reference:** The Stripe-specific billing sections below describe the pre-RevenueCat system. New deployments should follow [REVENUECAT_MIGRATION.md](REVENUECAT_MIGRATION.md); RevenueCat and the `revenuecat-webhook` function are now the subscription source of truth.

## Overview
We need a Supabase backend to handle:
- User authentication (email/password)
- Subscription management (free tier: 2000 words lifetime, pro: unlimited)
- API proxy for transcription requests (routes to Groq/OpenAI)
- Usage tracking and enforcement
- Stripe payment integration

---

## 1. Supabase Database Schema

Run this SQL in Supabase SQL Editor:

```sql
-- Users table (extends Supabase auth.users)
CREATE TABLE public.users (
  id UUID REFERENCES auth.users PRIMARY KEY,
  email TEXT NOT NULL,
  total_words_used INTEGER DEFAULT 0,
  subscription_tier TEXT DEFAULT 'free' CHECK (subscription_tier IN ('free', 'pro')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Subscriptions table
CREATE TABLE public.subscriptions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES public.users NOT NULL UNIQUE,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'canceled', 'past_due')),
  current_period_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable Row Level Security
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

-- RLS Policies: Users can read their own data
CREATE POLICY "Users can view own data" ON public.users
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own data" ON public.users
  FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Users can view own subscription" ON public.subscriptions
  FOR SELECT USING (auth.uid() = user_id);

-- Trigger to create user record on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email)
  VALUES (NEW.id, NEW.email);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Index for performance
CREATE INDEX idx_users_email ON public.users(email);
CREATE INDEX idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX idx_subscriptions_stripe_customer ON public.subscriptions(stripe_customer_id);
```

---

## 2. Supabase Edge Function: Transcription API Proxy

Create Edge Function at `supabase/functions/transcribe/index.ts`:

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Get authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      throw new Error('Missing authorization header')
    }

    // Initialize Supabase client
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )

    // Get authenticated user
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      throw new Error('Unauthorized')
    }

    // Fetch user data from database
    const { data: userData, error: dbError } = await supabaseClient
      .from('users')
      .select('*')
      .eq('id', user.id)
      .single()

    if (dbError || !userData) {
      throw new Error('User not found')
    }

    // Check subscription limits
    const FREE_WORD_LIMIT = 2000
    if (userData.subscription_tier === 'free' && userData.total_words_used >= FREE_WORD_LIMIT) {
      return new Response(
        JSON.stringify({
          error: 'Word limit reached. Please upgrade to continue.',
          code: 'LIMIT_REACHED'
        }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      )
    }

    // Parse request body
    const { audio, language = 'en' } = await req.json()

    if (!audio) {
      throw new Error('Missing audio data')
    }

    // Convert base64 to blob for Groq API
    const audioBuffer = Uint8Array.from(atob(audio), c => c.charCodeAt(0))

    // Create FormData for Groq API
    const formData = new FormData()
    formData.append('file', new Blob([audioBuffer], { type: 'audio/webm' }), 'audio.webm')
    formData.append('model', 'whisper-large-v3-turbo')
    formData.append('language', language)
    formData.append('response_format', 'json')

    // Call Groq API
    const groqApiKey = Deno.env.get('GROQ_API_KEY')
    const groqResponse = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${groqApiKey}`,
      },
      body: formData,
    })

    if (!groqResponse.ok) {
      const errorText = await groqResponse.text()
      throw new Error(`Groq API error: ${errorText}`)
    }

    const groqData = await groqResponse.json()
    const transcription = groqData.text || ''

    // Count words (split by whitespace)
    const wordCount = transcription.trim().split(/\s+/).filter(w => w.length > 0).length

    // Update user's word count in database
    const newTotalWords = userData.total_words_used + wordCount
    const { data: updatedUser, error: updateError } = await supabaseClient
      .from('users')
      .update({
        total_words_used: newTotalWords,
        updated_at: new Date().toISOString()
      })
      .eq('id', user.id)
      .select()
      .single()

    if (updateError) {
      console.error('Failed to update word count:', updateError)
      // Don't fail the request, just log the error
    }

    // Return transcription + updated user data
    return new Response(
      JSON.stringify({
        transcription,
        word_count: wordCount,
        user: updatedUser || { ...userData, total_words_used: newTotalWords }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    )

  } catch (error) {
    console.error('Error:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    )
  }
})
```

**Environment Variables Needed:**
- `GROQ_API_KEY` - Your Groq API key for transcription
- `SUPABASE_URL` - Automatically provided
- `SUPABASE_ANON_KEY` - Automatically provided

---

## 3. Stripe Webhook Handler

Create Edge Function at `supabase/functions/stripe-webhook/index.ts`:

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Stripe from 'https://esm.sh/stripe@14.21.0'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
  apiVersion: '2023-10-16',
})

const cryptoProvider = Stripe.createSubtleCryptoProvider()

serve(async (req) => {
  const signature = req.headers.get('Stripe-Signature')
  const body = await req.text()

  let event
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature!,
      Deno.env.get('STRIPE_WEBHOOK_SECRET')!,
      undefined,
      cryptoProvider
    )
  } catch (err) {
    return new Response(`Webhook Error: ${err.message}`, { status: 400 })
  }

  const supabaseAdmin = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  )

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session
        const customerId = session.customer as string
        const subscriptionId = session.subscription as string
        const customerEmail = session.customer_email

        // Find user by email
        const { data: user } = await supabaseAdmin
          .from('users')
          .select('id')
          .eq('email', customerEmail)
          .single()

        if (user) {
          // Update user to pro tier
          await supabaseAdmin
            .from('users')
            .update({ subscription_tier: 'pro' })
            .eq('id', user.id)

          // Create or update subscription record
          await supabaseAdmin
            .from('subscriptions')
            .upsert({
              user_id: user.id,
              stripe_customer_id: customerId,
              stripe_subscription_id: subscriptionId,
              status: 'active',
            })
        }
        break
      }

      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const subscription = event.data.object as Stripe.Subscription
        const customerId = subscription.customer as string

        // Find subscription by customer ID
        const { data: subData } = await supabaseAdmin
          .from('subscriptions')
          .select('user_id')
          .eq('stripe_customer_id', customerId)
          .single()

        if (subData) {
          const isActive = subscription.status === 'active'

          // Update subscription status
          await supabaseAdmin
            .from('subscriptions')
            .update({
              status: subscription.status,
              current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
            })
            .eq('stripe_customer_id', customerId)

          // Update user tier
          await supabaseAdmin
            .from('users')
            .update({ subscription_tier: isActive ? 'pro' : 'free' })
            .eq('id', subData.user_id)
        }
        break
      }
    }

    return new Response(JSON.stringify({ received: true }), { status: 200 })
  } catch (error) {
    console.error('Webhook handler error:', error)
    return new Response(`Webhook Error: ${error.message}`, { status: 500 })
  }
})
```

**Environment Variables Needed:**
- `STRIPE_SECRET_KEY` - Your Stripe secret key
- `STRIPE_WEBHOOK_SECRET` - Webhook signing secret from Stripe
- `SUPABASE_SERVICE_ROLE_KEY` - Admin key (automatically provided)

---

## 4. Supabase Auth Configuration

In Supabase Dashboard → Authentication → URL Configuration:

**Site URL:**
```
whispermate://auth
```

**Redirect URLs (add all):**
```
whispermate://auth
whispermate://payment/success
whispermate://payment/cancel
```

**Email Templates:**
- Enable "Confirm signup" email
- Customize to match your branding

---

## 5. Stripe Configuration

### Create Payment Link:
1. Go to Stripe Dashboard → Payment Links
2. Create new payment link:
   - Product: "WhisperMate Pro"
   - Price: $9.99/month (recurring)
   - After payment, redirect to: `whispermate://payment/success`
   - After cancel, redirect to: `whispermate://payment/cancel`

### Set up Webhook:
1. Stripe Dashboard → Developers → Webhooks
2. Add endpoint: `https://YOUR_PROJECT.supabase.co/functions/v1/stripe-webhook`
3. Select events:
   - `checkout.session.completed`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
4. Copy webhook signing secret → Add to Supabase Edge Function secrets

---

## 6. API Documentation for Mac Client

### Base URL:
```
https://YOUR_PROJECT.supabase.co
```

### Endpoints:

#### 1. Get User Data
```
GET /rest/v1/users
Headers:
  - apikey: YOUR_SUPABASE_ANON_KEY
  - Authorization: Bearer USER_ACCESS_TOKEN
  - Content-Type: application/json
  - Prefer: return=representation
```

Response:
```json
[{
  "id": "uuid",
  "email": "user@example.com",
  "total_words_used": 150,
  "subscription_tier": "free",
  "created_at": "2025-01-24T00:00:00Z",
  "updated_at": "2025-01-24T00:00:00Z"
}]
```

#### 2. Transcribe Audio
```
POST /functions/v1/transcribe
Headers:
  - apikey: YOUR_SUPABASE_ANON_KEY
  - Authorization: Bearer USER_ACCESS_TOKEN
  - Content-Type: application/json

Body:
{
  "audio": "base64_encoded_audio_data",
  "language": "en"
}
```

Response (Success):
```json
{
  "transcription": "This is the transcribed text",
  "word_count": 5,
  "user": {
    "id": "uuid",
    "email": "user@example.com",
    "total_words_used": 155,
    "subscription_tier": "free",
    "created_at": "2025-01-24T00:00:00Z",
    "updated_at": "2025-01-24T00:00:00Z"
  }
}
```

Response (Limit Reached - 403):
```json
{
  "error": "Word limit reached. Please upgrade to continue.",
  "code": "LIMIT_REACHED"
}
```

---

## 7. Testing Checklist

### Database:
- [ ] Users table created with correct schema
- [ ] Subscriptions table created
- [ ] RLS policies enabled and working
- [ ] Trigger creates user record on signup

### Edge Functions:
- [ ] `transcribe` function deployed
- [ ] Function has GROQ_API_KEY environment variable
- [ ] `stripe-webhook` function deployed
- [ ] Webhook has STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET

### Auth:
- [ ] Email/password authentication enabled
- [ ] Redirect URLs configured
- [ ] Email templates customized

### Stripe:
- [ ] Payment link created ($9.99/month)
- [ ] Redirect URLs set correctly
- [ ] Webhook endpoint added
- [ ] Webhook events selected
- [ ] Test mode works

### Integration Tests:
- [ ] New user signup creates database record
- [ ] Transcription API accepts authenticated requests
- [ ] Word count increments correctly
- [ ] Free users blocked at 2000 words
- [ ] Pro users have unlimited access
- [ ] Stripe payment upgrades user to pro
- [ ] Webhook updates subscription status

---

## 8. Required Credentials to Send Back

Once complete, please provide:

1. **Supabase Project URL**: `https://xxxxx.supabase.co`
2. **Supabase Anon Key**: `eyJhbG...` (public key, safe for client)
3. **Stripe Payment Link**: `https://buy.stripe.com/xxxxx`

These will be added to the Mac app's `Secrets.plist`.

---

## Notes

- **Free tier**: 2000 words LIFETIME (not monthly) - once used, must upgrade
- **Pro tier**: Unlimited words forever
- **API costs**: All transcription requests from Pro users use YOUR Groq API key (included in subscription)
- **Free users**: Still use the proxy (for usage tracking), but you might want them to bring their own API key in the future to reduce costs
- **Security**: Row Level Security ensures users can only access their own data
- **CORS**: Edge functions include CORS headers for web compatibility

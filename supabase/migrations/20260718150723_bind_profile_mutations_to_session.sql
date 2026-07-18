-- Bind profile mutations to the account that initiated them. If the client
-- changes sessions before the request is authorized, the database rejects the
-- operation before touching either account.

create or replace function public.increment_monthly_word_count_for_session(
    expected_user_id uuid,
    words_to_add integer
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    requester_id uuid := (select auth.uid());
    updated_profile public.profiles;
begin
    if requester_id is null
        or expected_user_id is null
        or requester_id <> expected_user_id then
        raise exception using
            errcode = '42501',
            message = 'The signed-in account changed before the update could be completed';
    end if;

    if words_to_add is null or words_to_add <= 0 then
        raise exception using
            errcode = '22023',
            message = 'Word count must be greater than zero';
    end if;

    update public.profiles
    set monthly_word_count = coalesce(monthly_word_count, 0) + words_to_add,
        updated_at = now()
    where user_id = expected_user_id
    returning * into updated_profile;

    if updated_profile.user_id is null then
        raise exception using
            errcode = 'P0002',
            message = 'Your profile could not be found';
    end if;

    return updated_profile;
end;
$$;

create or replace function public.ensure_referral_code_for_session(
    expected_user_id uuid
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    requester_id uuid := (select auth.uid());
    updated_profile public.profiles;
begin
    if requester_id is null
        or expected_user_id is null
        or requester_id <> expected_user_id then
        raise exception using
            errcode = '42501',
            message = 'The signed-in account changed before the update could be completed';
    end if;

    update public.profiles
    set referral_code = coalesce(
            referral_code,
            public.make_referral_code(user_id)
        ),
        updated_at = now()
    where user_id = expected_user_id
    returning * into updated_profile;

    if updated_profile.user_id is null then
        raise exception using
            errcode = 'P0002',
            message = 'Your profile could not be found';
    end if;

    return updated_profile;
end;
$$;

create or replace function public.redeem_referral_code_for_session(
    code text,
    expected_user_id uuid
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    requester_id uuid := (select auth.uid());
    cleaned_code text := upper(trim(code));
    referrer public.profiles;
    updated_profile public.profiles;
    bonus integer := 2000;
begin
    if requester_id is null
        or expected_user_id is null
        or requester_id <> expected_user_id then
        raise exception using
            errcode = '42501',
            message = 'The signed-in account changed before the update could be completed';
    end if;

    if cleaned_code is null or cleaned_code = '' then
        raise exception using
            errcode = '22023',
            message = 'Enter an invite code';
    end if;

    select *
    into referrer
    from public.profiles
    where referral_code = cleaned_code;

    if referrer.user_id is null then
        raise exception using
            errcode = 'P0002',
            message = 'Invite code was not found';
    end if;

    if referrer.user_id = expected_user_id then
        raise exception using
            errcode = '22023',
            message = 'You cannot use your own invite code';
    end if;

    insert into public.referrals (referrer_user_id, referred_user_id, bonus_words)
    values (referrer.user_id, expected_user_id, bonus);

    update public.profiles
    set referral_bonus_words = referral_bonus_words + bonus,
        updated_at = now()
    where user_id = referrer.user_id;

    update public.profiles
    set referred_by_user_id = referrer.user_id,
        referral_bonus_words = referral_bonus_words + bonus,
        referral_code = coalesce(
            referral_code,
            public.make_referral_code(user_id)
        ),
        updated_at = now()
    where user_id = expected_user_id
    returning * into updated_profile;

    if updated_profile.user_id is null then
        raise exception using
            errcode = 'P0002',
            message = 'Your profile could not be found';
    end if;

    return updated_profile;
exception
    when unique_violation then
        raise exception using
            errcode = '23505',
            message = 'An invite has already been used for this account';
end;
$$;

-- Postgres grants function execution to PUBLIC by default. These profile
-- mutation endpoints are intentionally available only to signed-in users.
revoke execute on function public.increment_monthly_word_count_for_session(uuid, integer)
    from public, anon, authenticated, service_role;
revoke execute on function public.ensure_referral_code_for_session(uuid)
    from public, anon, authenticated, service_role;
revoke execute on function public.redeem_referral_code_for_session(text, uuid)
    from public, anon, authenticated, service_role;

grant execute on function public.increment_monthly_word_count_for_session(uuid, integer)
    to authenticated;
grant execute on function public.ensure_referral_code_for_session(uuid)
    to authenticated;
grant execute on function public.redeem_referral_code_for_session(text, uuid)
    to authenticated;

-- Existing Android clients still call these names with a session-bound access
-- token. Keep the endpoints, but remove anonymous/default execution.
revoke execute on function public.ensure_referral_code()
    from public, anon, authenticated, service_role;
revoke execute on function public.redeem_referral_code(text)
    from public, anon, authenticated, service_role;
grant execute on function public.ensure_referral_code() to authenticated;
grant execute on function public.redeem_referral_code(text) to authenticated;

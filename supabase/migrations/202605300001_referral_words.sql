alter table public.profiles
    add column if not exists referral_code text unique,
    add column if not exists referred_by_user_id uuid references public.profiles(user_id),
    add column if not exists referral_bonus_words integer not null default 0;

create table if not exists public.referrals (
    id uuid primary key default gen_random_uuid(),
    referrer_user_id uuid not null references public.profiles(user_id) on delete cascade,
    referred_user_id uuid not null references public.profiles(user_id) on delete cascade,
    bonus_words integer not null default 2000,
    created_at timestamptz not null default now(),
    unique (referred_user_id)
);

alter table public.referrals enable row level security;

drop policy if exists "Users can view own referrals" on public.referrals;
create policy "Users can view own referrals"
    on public.referrals for select
    using (
        auth.uid() = referrer_user_id
        or auth.uid() = referred_user_id
    );

create or replace function public.make_referral_code(seed uuid)
returns text
language sql
stable
as $$
    select upper(substr(replace(seed::text, '-', ''), 1, 8));
$$;

create or replace function public.ensure_referral_code()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
    updated_profile public.profiles;
begin
    update public.profiles
    set referral_code = coalesce(referral_code, public.make_referral_code(user_id)),
        updated_at = now()
    where user_id = auth.uid()
    returning * into updated_profile;

    if updated_profile.user_id is null then
        raise exception 'Profile not found';
    end if;

    return updated_profile;
end;
$$;

create or replace function public.redeem_referral_code(code text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
    cleaned_code text := upper(trim(code));
    referrer public.profiles;
    updated_profile public.profiles;
    bonus integer := 2000;
begin
    if cleaned_code = '' then
        raise exception 'Invite code is required';
    end if;

    select *
    into referrer
    from public.profiles
    where referral_code = cleaned_code;

    if referrer.user_id is null then
        raise exception 'Invite code was not found';
    end if;

    if referrer.user_id = auth.uid() then
        raise exception 'You cannot use your own invite code';
    end if;

    insert into public.referrals (referrer_user_id, referred_user_id, bonus_words)
    values (referrer.user_id, auth.uid(), bonus);

    update public.profiles
    set referral_bonus_words = referral_bonus_words + bonus,
        updated_at = now()
    where user_id = referrer.user_id;

    update public.profiles
    set referred_by_user_id = referrer.user_id,
        referral_bonus_words = referral_bonus_words + bonus,
        referral_code = coalesce(referral_code, public.make_referral_code(user_id)),
        updated_at = now()
    where user_id = auth.uid()
    returning * into updated_profile;

    return updated_profile;
exception
    when unique_violation then
        raise exception 'An invite has already been used for this account';
end;
$$;

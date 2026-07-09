create or replace function public.delete_current_user_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := auth.uid();
begin
    if current_user_id is null then
        raise exception 'Login is required';
    end if;

    if to_regclass('public.subscriptions') is not null then
        execute 'delete from public.subscriptions where user_id = $1'
        using current_user_id;
    end if;

    if to_regclass('public.referrals') is not null then
        execute 'delete from public.referrals where referrer_user_id = $1 or referred_user_id = $1'
        using current_user_id;
    end if;

    if to_regclass('public.profiles') is not null then
        execute 'update public.profiles set referred_by_user_id = null where referred_by_user_id = $1'
        using current_user_id;

        execute 'delete from public.profiles where user_id = $1'
        using current_user_id;
    end if;

    delete from auth.users
    where id = current_user_id;

    if not found then
        raise exception 'Account was not found';
    end if;
end;
$$;

revoke all on function public.delete_current_user_account() from public;
revoke all on function public.delete_current_user_account() from anon;
grant execute on function public.delete_current_user_account() to authenticated;

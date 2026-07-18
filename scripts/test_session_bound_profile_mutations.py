#!/usr/bin/env python3
"""Exercise session-bound profile RPCs in a disposable Postgres database."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CONTAINER_NAME = f"aidictation-profile-rpc-contract-{os.getpid()}"
POSTGRES_IMAGE = os.environ.get("POSTGRES_IMAGE", "postgres:16-alpine")
ACCOUNT_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ACCOUNT_B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
ACCOUNT_C = "cccccccc-cccc-cccc-cccc-cccccccccccc"
MISSING_ACCOUNT = "dddddddd-dddd-dddd-dddd-dddddddddddd"


def run(
    arguments: list[str],
    *,
    input_text: str | None = None,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        input=input_text,
        text=True,
        capture_output=capture_output,
    )


def psql(sql: str) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "docker",
            "exec",
            "-i",
            CONTAINER_NAME,
            "psql",
            "-U",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-At",
        ],
        input_text=sql,
    )


SETUP_SQL = r"""
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;

create schema auth;
grant usage on schema auth, public to anon, authenticated, service_role;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create table public.profiles (
    user_id uuid primary key,
    email text not null,
    monthly_word_count integer not null default 0,
    subscription_status text not null default 'free',
    updated_at timestamptz not null default now()
);

\ir /repo/supabase/migrations/202605300001_referral_words.sql
\ir /repo/supabase/migrations/20260718150723_bind_profile_mutations_to_session.sql
"""


CONTRACT_SQL = f"""
insert into public.profiles (user_id, email, referral_code)
values
    ('{ACCOUNT_A}', 'a@example.com', 'INVITEA'),
    ('{ACCOUNT_B}', 'b@example.com', null),
    ('{ACCOUNT_C}', 'c@example.com', null);

do $$
declare
    signature text;
begin
    foreach signature in array array[
        'public.increment_monthly_word_count_for_session(uuid,integer)',
        'public.ensure_referral_code_for_session(uuid)',
        'public.redeem_referral_code_for_session(text,uuid)'
    ] loop
        if has_function_privilege('anon', signature, 'execute') then
            raise exception 'anon can execute %', signature;
        end if;
        if has_function_privilege('service_role', signature, 'execute') then
            raise exception 'service_role can execute %', signature;
        end if;
        if not has_function_privilege('authenticated', signature, 'execute') then
            raise exception 'authenticated cannot execute %', signature;
        end if;
    end loop;

    if has_function_privilege('anon', 'public.ensure_referral_code()', 'execute')
        or has_function_privilege('anon', 'public.redeem_referral_code(text)', 'execute') then
        raise exception 'anon can execute a legacy referral RPC';
    end if;
    if not has_function_privilege('authenticated', 'public.ensure_referral_code()', 'execute')
        or not has_function_privilege(
            'authenticated',
            'public.redeem_referral_code(text)',
            'execute'
        ) then
        raise exception 'authenticated cannot execute a legacy referral RPC';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub', '{ACCOUNT_A}', false);
set role authenticated;
select public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 5);
select public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 7);
reset role;

do $$
begin
    if (select monthly_word_count from public.profiles where user_id = '{ACCOUNT_A}') <> 12 then
        raise exception 'additive word-count updates failed';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub', '{ACCOUNT_B}', false);
set role authenticated;
do $$
begin
    begin
        perform public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 20);
        raise exception 'mismatched account was accepted';
    exception when sqlstate '42501' then null;
    end;

    begin
        perform public.redeem_referral_code_for_session('INVITEA', '{ACCOUNT_C}');
        raise exception 'mismatched referral account was accepted';
    exception when sqlstate '42501' then null;
    end;
end;
$$;
reset role;

do $$
begin
    if (select monthly_word_count from public.profiles where user_id = '{ACCOUNT_A}') <> 12 then
        raise exception 'mismatched session changed account A';
    end if;
    if exists (select 1 from public.referrals where referred_user_id = '{ACCOUNT_C}') then
        raise exception 'mismatched session created a referral for account C';
    end if;
end;
$$;

reset request.jwt.claim.sub;
set role authenticated;
do $$
begin
    begin
        perform public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 1);
        raise exception 'missing JWT identity was accepted';
    exception when sqlstate '42501' then null;
    end;
end;
$$;
reset role;

select set_config('request.jwt.claim.sub', '{ACCOUNT_A}', false);
set role authenticated;
do $$
begin
    begin
        perform public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 0);
        raise exception 'zero increment was accepted';
    exception when sqlstate '22023' then null;
    end;
    begin
        perform public.redeem_referral_code_for_session('INVITEA', '{ACCOUNT_A}');
        raise exception 'self-referral was accepted';
    exception when sqlstate '22023' then null;
    end;
end;
$$;
reset role;

select set_config('request.jwt.claim.sub', '{MISSING_ACCOUNT}', false);
set role authenticated;
do $$
begin
    begin
        perform public.increment_monthly_word_count_for_session('{MISSING_ACCOUNT}', 1);
        raise exception 'missing profile was accepted';
    exception when sqlstate 'P0002' then null;
    end;
end;
$$;
reset role;

select set_config('request.jwt.claim.sub', '{ACCOUNT_C}', false);
set role authenticated;
select public.ensure_referral_code_for_session('{ACCOUNT_C}');
select public.ensure_referral_code_for_session('{ACCOUNT_C}');
reset role;

do $$
begin
    if (select referral_code from public.profiles where user_id = '{ACCOUNT_C}') <> 'CCCCCCCC' then
        raise exception 'stable referral code was not created for account C';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub', '{ACCOUNT_B}', false);
set role authenticated;
select public.redeem_referral_code_for_session('INVITEA', '{ACCOUNT_B}');
do $$
begin
    begin
        perform public.redeem_referral_code_for_session('INVITEA', '{ACCOUNT_B}');
        raise exception 'duplicate referral was accepted';
    exception when unique_violation then null;
    end;
end;
$$;
reset role;

do $$
begin
    if (select count(*) from public.referrals where referred_user_id = '{ACCOUNT_B}') <> 1 then
        raise exception 'referral was not recorded exactly once';
    end if;
    if (select referral_bonus_words from public.profiles where user_id = '{ACCOUNT_A}') <> 2000
        or (select referral_bonus_words from public.profiles where user_id = '{ACCOUNT_B}') <> 2000 then
        raise exception 'duplicate referral changed a bonus outside the committed transaction';
    end if;
end;
$$;
"""


def wait_until_ready() -> None:
    # The official image briefly accepts connections on its temporary setup
    # server, then restarts Postgres. Wait for that setup phase to finish before
    # trusting pg_isready so CI cannot connect during the restart handoff.
    for _ in range(80):
        logs = subprocess.run(
            ["docker", "logs", CONTAINER_NAME],
            text=True,
            capture_output=True,
        )
        initialization_complete = (
            "PostgreSQL init process complete; ready for start up."
            in f"{logs.stdout}\n{logs.stderr}"
        )
        readiness = subprocess.run(
            ["docker", "exec", CONTAINER_NAME, "pg_isready", "-U", "postgres"],
            text=True,
            capture_output=True,
        )
        if initialization_complete and readiness.returncode == 0:
            return
        time.sleep(0.25)
    raise RuntimeError("Disposable Postgres did not become ready")


def concurrent_increment() -> None:
    sql = (
        f"select set_config('request.jwt.claim.sub', '{ACCOUNT_A}', false);"
        "set role authenticated;"
        f"select public.increment_monthly_word_count_for_session('{ACCOUNT_A}', 1);"
    )
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(psql, sql) for _ in range(8)]
        for future in futures:
            future.result()

    result = psql(
        f"select monthly_word_count from public.profiles where user_id = '{ACCOUNT_A}';"
    )
    count = int(result.stdout.strip().splitlines()[-1])
    if count != 20:
        raise RuntimeError(f"Concurrent increments produced {count}, expected 20")


def main() -> int:
    try:
        run(
            [
                "docker",
                "run",
                "--name",
                CONTAINER_NAME,
                "-e",
                "POSTGRES_PASSWORD=contract",
                "-d",
                "-v",
                f"{REPOSITORY_ROOT}:/repo:ro",
                POSTGRES_IMAGE,
            ]
        )
        wait_until_ready()
        psql(SETUP_SQL)
        psql(CONTRACT_SQL)
        concurrent_increment()
        print("Session-bound profile mutation contract passed")
        return 0
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            sys.stderr.write(error.stderr or error.stdout or str(error))
        else:
            sys.stderr.write(f"{error}\n")
        return 1
    finally:
        subprocess.run(
            ["docker", "rm", "-f", CONTAINER_NAME],
            text=True,
            capture_output=True,
        )


if __name__ == "__main__":
    raise SystemExit(main())

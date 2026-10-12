-- 老师行为盘口 · 共享下注后端
-- 用法：Supabase Dashboard → SQL Editor → New query → 粘贴整段 → Run
-- 安全模型：两张表都开 RLS 且不加任何 policy，所以匿名 key 碰不到表本身；
--          所有读写只能走下面 6 个 security definer 函数，口令（host_token）永不返回给前端。

-- ---------- 表 ----------
create table if not exists public.pankou_board (
  id         text primary key,
  state      jsonb       not null,
  rev        integer     not null default 1,
  host_token text        not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pankou_bet (
  id         bigserial primary key,
  board_id   text        not null references public.pankou_board(id) on delete cascade,
  market_id  text        not null,
  opt_id     text        not null,
  who        text        not null,
  amt        numeric(12,2) not null check (amt > 0 and amt <= 100000),
  created_at timestamptz not null default now()
);

create index if not exists pankou_bet_board_idx on public.pankou_bet (board_id, id);

alter table public.pankou_board enable row level security;
alter table public.pankou_bet   enable row level security;
-- 故意不建 policy：匿名 key 直连表会一律被拒。

-- ---------- 读 ----------
-- 任何人可读：盘口结构 + 所有注码。host_token 不在返回里。
create or replace function public.pankou_get(p_board text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b public.pankou_board;
begin
  select * into b from pankou_board where id = p_board;
  if not found then
    return jsonb_build_object('exists', false);
  end if;
  return jsonb_build_object(
    'exists',  true,
    'rev',     b.rev,
    'state',   b.state,
    'updated', b.updated_at,
    'bets',    coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',  id::text,
               'm',   market_id,
               'o',   opt_id,
               'who', who,
               'amt', amt,
               't',   created_at)
             order by id)
      from pankou_bet where board_id = p_board), '[]'::jsonb)
  );
end;
$$;

-- ---------- 开盘人：建盘 / 认领 ----------
-- 盘口不存在 → 用这个口令建；已存在 → 口令对得上才算认领成功（换手机用同一口令即可拿回开盘权）。
create or replace function public.pankou_claim(p_board text, p_token text, p_state jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b public.pankou_board;
begin
  if length(coalesce(p_token, '')) < 4 then
    raise exception 'token_short';
  end if;
  if p_board !~ '^[a-zA-Z0-9_-]{3,40}$' then
    raise exception 'bad_board_id';
  end if;

  select * into b from pankou_board where id = p_board;
  if not found then
    -- 只有「开盘人带着自己的盘口内容来建盘」才允许新建。
    -- 同学点“我是开盘人”时传的是空 state：盘口还不存在就直接拒绝，
    -- 否则随便猜一个编号就能把空盘口占下来、把真开盘人挡在外面。
    if p_state is null or (p_state -> 'markets') is null then
      raise exception 'no_board';
    end if;
    insert into pankou_board (id, state, rev, host_token)
    values (p_board, p_state, 1, p_token);
    return jsonb_build_object('ok', true, 'created', true, 'rev', 1);
  end if;

  if b.host_token <> p_token then
    raise exception 'bad_token';
  end if;
  return jsonb_build_object('ok', true, 'created', false, 'rev', b.rev);
end;
$$;

-- ---------- 开盘人：保存盘口结构 ----------
-- 只存结构（标题/各盘问题/选项/开奖结果）。注码是另一张表，这里顺手清掉指向已删选项/已删盘的孤儿注码。
-- p_rev 传当前已知版本号做乐观锁：对不上就返回 conflict + 最新数据，不覆盖别人的改动。
create or replace function public.pankou_save(p_board text, p_token text, p_state jsonb, p_rev integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b public.pankou_board; new_rev integer;
begin
  select * into b from pankou_board where id = p_board for update;
  if not found then raise exception 'no_board'; end if;
  if b.host_token <> p_token then raise exception 'bad_token'; end if;

  if p_rev is not null and p_rev <> b.rev then
    return jsonb_build_object('ok', false, 'err', 'conflict', 'rev', b.rev);
  end if;

  new_rev := b.rev + 1;
  update pankou_board
     set state = p_state, rev = new_rev, updated_at = now()
   where id = p_board;

  delete from pankou_bet bet
   where bet.board_id = p_board
     and not exists (
       select 1
         from jsonb_array_elements(p_state -> 'markets') m,
              jsonb_array_elements(m -> 'opts') o
        where m ->> 'id' = bet.market_id
          and o ->> 'id' = bet.opt_id);

  return jsonb_build_object('ok', true, 'rev', new_rev);
end;
$$;

-- ---------- 所有人：下注 ----------
-- 只能往「这个盘口里真实存在、且还开着」的选项上押。单盘最多 400 注，防刷。
create or replace function public.pankou_place_bet(p_board text, p_market text, p_opt text, p_who text, p_amt numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare st jsonb; who text; amt numeric; n integer; new_id bigint;
begin
  who := btrim(coalesce(p_who, ''));
  amt := round(coalesce(p_amt, 0), 2);
  if who = '' then raise exception 'no_who'; end if;
  if length(who) > 16 then who := left(who, 16); end if;
  if amt <= 0 or amt > 100000 then raise exception 'bad_amt'; end if;

  select state into st from pankou_board where id = p_board;
  if st is null then raise exception 'no_board'; end if;

  if not exists (
    select 1
      from jsonb_array_elements(st -> 'markets') m
     where m ->> 'id' = p_market
       and coalesce(m ->> 'status', 'open') = 'open'
       and exists (select 1 from jsonb_array_elements(m -> 'opts') o where o ->> 'id' = p_opt)
  ) then
    raise exception 'market_closed';
  end if;

  select count(*) into n from pankou_bet where board_id = p_board and market_id = p_market;
  if n >= 400 then raise exception 'too_many'; end if;

  insert into pankou_bet (board_id, market_id, opt_id, who, amt)
  values (p_board, p_market, p_opt, who, amt)
  returning id into new_id;

  return jsonb_build_object('ok', true, 'id', new_id::text);
end;
$$;

-- ---------- 开盘人：删一注 ----------
create or replace function public.pankou_del_bet(p_board text, p_token text, p_bet text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b public.pankou_board;
begin
  select * into b from pankou_board where id = p_board;
  if not found then raise exception 'no_board'; end if;
  if b.host_token <> p_token then raise exception 'bad_token'; end if;
  delete from pankou_bet where board_id = p_board and id = p_bet::bigint;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- 开盘人：清空注码（重新开局） ----------
-- p_market 传 null = 清空整个盘口的注码；传某盘 id = 只清那一盘。
create or replace function public.pankou_clear_bets(p_board text, p_token text, p_market text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b public.pankou_board; n integer;
begin
  select * into b from pankou_board where id = p_board;
  if not found then raise exception 'no_board'; end if;
  if b.host_token <> p_token then raise exception 'bad_token'; end if;

  delete from pankou_bet
   where board_id = p_board
     and (p_market is null or market_id = p_market);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'deleted', n);
end;
$$;

-- ---------- 权限：只放开这 6 个函数 ----------
revoke all on function public.pankou_get(text)                                        from public;
revoke all on function public.pankou_claim(text, text, jsonb)                         from public;
revoke all on function public.pankou_save(text, text, jsonb, integer)                 from public;
revoke all on function public.pankou_place_bet(text, text, text, text, numeric)       from public;
revoke all on function public.pankou_del_bet(text, text, text)                        from public;
revoke all on function public.pankou_clear_bets(text, text, text)                     from public;

grant execute on function public.pankou_get(text)                                  to anon, authenticated;
grant execute on function public.pankou_claim(text, text, jsonb)                   to anon, authenticated;
grant execute on function public.pankou_save(text, text, jsonb, integer)           to anon, authenticated;
grant execute on function public.pankou_place_bet(text, text, text, text, numeric) to anon, authenticated;
grant execute on function public.pankou_del_bet(text, text, text)                  to anon, authenticated;
grant execute on function public.pankou_clear_bets(text, text, text)               to anon, authenticated;

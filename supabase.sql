-- 洛亚提自由联邦 · 市政厅官网后端（Supabase）
-- 用法：打开 Supabase 控制台 → SQL Editor → 新建查询 → 整份粘贴 → Run
-- 执行完再按 README 第六节填 Project URL 和 anon key

-- ============ 表结构 ============

-- 成员档案：一个登录账号一条，username 用于头衔和白名单匹配
create table if not exists public.members (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  username text not null unique,
  created_at timestamptz not null default now()
);

-- 注册白名单：不在这里的名字，注册接口会被行级安全挡掉
create table if not exists public.whitelist (
  name text primary key
);

-- 头衔授权：name → title
create table if not exists public.titles (
  name text primary key,
  title text not null
);

-- 页面正文：id 与站点里的 data-id 一致（home / about / gov …）
create table if not exists public.pages (
  id text primary key,
  title text,
  paragraphs jsonb not null default '[]'::jsonb
);

-- 发布内容：pos 决定挂在哪一页
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author text not null,
  author_title text,
  pos text not null default 'home',
  body text not null,
  image text default '',
  created_at timestamptz not null default now()
);

-- 评论
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists comments_post_id_idx on public.comments (post_id);

-- ============ 服主判定 ============
-- 谁的 members.username 是 gun7z，谁就是服主（大小写不敏感）
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members m
    where m.user_id = auth.uid() and lower(m.username) = 'gun7z'
  );
$$;

-- ============ 行级安全 RLS ============
alter table public.members   enable row level security;
alter table public.whitelist enable row level security;
alter table public.titles    enable row level security;
alter table public.pages     enable row level security;
alter table public.posts     enable row level security;
alter table public.comments  enable row level security;

-- members：谁都能读（前端要判断自己的用户名），只能写自己那一条，且名字必须在白名单里
drop policy if exists m_read on public.members;
create policy m_read on public.members for select using (true);

drop policy if exists m_insert on public.members;
create policy m_insert on public.members for insert with check (
  user_id = auth.uid()
  and exists (select 1 from public.whitelist w where lower(w.name) = lower(username))
);

-- whitelist：只能服主增删改
drop policy if exists wl_read on public.whitelist;
create policy wl_read on public.whitelist for select using (true);

drop policy if exists wl_owner on public.whitelist;
create policy wl_owner on public.whitelist for all using (public.is_owner()) with check (public.is_owner());

-- titles：只能服主授予 / 撤销
drop policy if exists ti_read on public.titles;
create policy ti_read on public.titles for select using (true);

drop policy if exists ti_owner on public.titles;
create policy ti_owner on public.titles for all using (public.is_owner()) with check (public.is_owner());

-- pages：只能服主改
drop policy if exists pg_read on public.pages;
create policy pg_read on public.pages for select using (true);

drop policy if exists pg_owner on public.pages;
create policy pg_owner on public.pages for all using (public.is_owner()) with check (public.is_owner());

-- posts：所有人可读；只有登录成员能发，且作者名必须是自己；只有服主能删
drop policy if exists po_read on public.posts;
create policy po_read on public.posts for select using (true);

drop policy if exists po_insert on public.posts;
create policy po_insert on public.posts for insert with check (
  exists (select 1 from public.members m where m.user_id = auth.uid() and m.username = author)
);

drop policy if exists po_delete on public.posts;
create policy po_delete on public.posts for delete using (public.is_owner());

-- comments：所有人可读；登录成员可发；本人或服主可删
drop policy if exists co_read on public.comments;
create policy co_read on public.comments for select using (true);

drop policy if exists co_insert on public.comments;
create policy co_insert on public.comments for insert with check (
  exists (select 1 from public.members m where m.user_id = auth.uid() and m.username = author)
);

drop policy if exists co_delete on public.comments;
create policy co_delete on public.comments for delete using (
  public.is_owner()
  or exists (select 1 from public.members m where m.user_id = auth.uid() and m.username = author)
);

-- ============ 权限 ============
grant usage on schema public to anon, authenticated;
grant select on public.posts, public.comments, public.titles, public.whitelist, public.pages, public.members to anon, authenticated;
grant insert, update, delete on public.posts, public.comments, public.titles, public.whitelist, public.pages to authenticated;
grant insert on public.members to authenticated;

-- ============ 实时（有人发帖 / 评论，全员页面自动刷新） ============
do $$
begin
  begin
    alter publication supabase_realtime add table public.posts;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.comments;
  exception when duplicate_object then null;
  end;
end $$;

-- ============ 初始数据 ============
insert into public.whitelist (name) values ('Gun7z') on conflict do nothing;

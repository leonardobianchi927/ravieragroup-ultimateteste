-- RAVIERAGROUP ULTIMATE | INSTALAÇÃO COMPLETA EM PROJETO SUPABASE NOVO
-- Execute no SQL Editor de um projeto DE TESTES, não no projeto oficial.
-- SQL para Supabase PostgreSQL; nenhuma conta Auth ou motorista é criado automaticamente como gerente.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.user_profiles (
 id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 display_name text NOT NULL DEFAULT 'Motorista',
 role text NOT NULL DEFAULT 'driver' CHECK (role IN ('admin','manager','driver')),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.drivers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL,
 qra text NOT NULL DEFAULT '',
 money text NOT NULL DEFAULT '',
 truck text NOT NULL DEFAULT '',
 trailer text NOT NULL DEFAULT '',
 license text NOT NULL DEFAULT '',
 fines text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS drivers_name_idx ON public.drivers(name);

-- Perfis surgem quando uma conta é criada em Authentication.
CREATE OR REPLACE FUNCTION public.raviera_create_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.user_profiles(id, display_name, role)
 VALUES (NEW.id, COALESCE(NULLIF(split_part(NEW.email,'@',1),''),'Motorista'), 'driver')
 ON CONFLICT (id) DO NOTHING;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS raviera_auth_profile_created ON auth.users;
CREATE TRIGGER raviera_auth_profile_created AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.raviera_create_profile();
-- Preenche perfis de usuários de teste já existentes (sem promover privilégios).
INSERT INTO public.user_profiles(id,display_name,role)
SELECT id,COALESCE(NULLIF(split_part(email,'@',1),''),'Motorista'),'driver'
FROM auth.users ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.raviera_is_manager() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT EXISTS(SELECT 1 FROM public.user_profiles p
 WHERE p.id=(SELECT auth.uid()) AND p.role IN ('admin','manager'));
$$;
REVOKE ALL ON FUNCTION public.raviera_is_manager() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.raviera_is_manager() TO authenticated;

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.drivers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rv_profiles_select ON public.user_profiles;
CREATE POLICY rv_profiles_select ON public.user_profiles FOR SELECT TO authenticated USING (true);
-- Não há política de UPDATE de user_profiles: cargos só pelo SQL Editor (ou backend seguro).
DROP POLICY IF EXISTS rv_drivers_select ON public.drivers;
CREATE POLICY rv_drivers_select ON public.drivers FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS rv_drivers_insert ON public.drivers;
CREATE POLICY rv_drivers_insert ON public.drivers FOR INSERT TO authenticated WITH CHECK ((SELECT public.raviera_is_manager()));
DROP POLICY IF EXISTS rv_drivers_update ON public.drivers;
CREATE POLICY rv_drivers_update ON public.drivers FOR UPDATE TO authenticated
 USING ((SELECT public.raviera_is_manager())) WITH CHECK ((SELECT public.raviera_is_manager()));
DROP POLICY IF EXISTS rv_drivers_delete ON public.drivers;
CREATE POLICY rv_drivers_delete ON public.drivers FOR DELETE TO authenticated USING ((SELECT public.raviera_is_manager()));
COMMIT;

-- ETAPA 2: CALENDÁRIO
BEGIN;
-- Reexecutável: atualiza apenas políticas e gatilhos com os mesmos nomes; não apaga registros.
-- Execute no SQL Editor do mesmo projeto Supabase usado pelo site.
create extension if not exists pgcrypto;
create table if not exists public.convoys (
 id uuid primary key default gen_random_uuid(),
 title text not null check (length(title) between 1 and 100),
 event_date date not null,
 event_time time not null,
 map_name text not null,
 server text not null default '',
 trailer text not null default '',
 organizer text not null default '',
 description text not null default '',
 status text not null default 'scheduled' check(status in ('scheduled','cancelled','finished')),
 created_at timestamptz not null default now()
);
create index if not exists convoys_date_idx on public.convoys(event_date);
alter table public.convoys enable row level security;
DROP POLICY IF EXISTS "Motoristas autenticados consultam comboios" ON public.convoys;
create policy "Motoristas autenticados consultam comboios" on public.convoys for select to authenticated using (true);
DROP POLICY IF EXISTS "Gestores cadastram comboios" ON public.convoys;
create policy "Gestores cadastram comboios" on public.convoys for insert to authenticated with check (
 exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role in ('admin','manager'))
);
DROP POLICY IF EXISTS "Gestores editam comboios" ON public.convoys;
create policy "Gestores editam comboios" on public.convoys for update to authenticated using (
 exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role in ('admin','manager'))
) with check (
 exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role in ('admin','manager'))
);
DROP POLICY IF EXISTS "Gestores excluem comboios" ON public.convoys;
create policy "Gestores excluem comboios" on public.convoys for delete to authenticated using (
 exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role in ('admin','manager'))
);

COMMIT;

-- ETAPA 3: FINANÇAS, VIAGENS, AVISOS E GERÊNCIA
BEGIN;
-- Reexecutável: atualiza apenas políticas e gatilhos com os mesmos nomes; não apaga registros.
-- Execute no SQL Editor do projeto Supabase existente.
-- Mantenha as tabelas drivers e user_profiles já usadas pelo site.
create extension if not exists pgcrypto;
create or replace function public.raviera_is_manager() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.user_profiles where id=(select auth.uid()) and role in ('admin','manager'));
$$;
revoke all on function public.raviera_is_manager() from public;
grant execute on function public.raviera_is_manager() to authenticated;

create table if not exists public.trips(id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.drivers(id),trip_date date not null,origin text not null,destination text not null,distance_km numeric not null check(distance_km>0 and distance_km<=100000),notes text not null default '',status text not null default 'pending' check(status in ('pending','approved','rejected')),created_by uuid not null default auth.uid(),created_at timestamptz not null default now());
create table if not exists public.event_participations(id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.drivers(id),convoy_id uuid not null references public.convoys(id),status text not null default 'pending' check(status in ('pending','approved','rejected')),created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),unique(driver_id,convoy_id));
create table if not exists public.wallet_entries(id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.drivers(id),kind text not null check(kind in ('credit','debit')),amount numeric(14,2) not null check(amount>0),description text not null,created_at timestamptz not null default now());
create table if not exists public.company_notices(id uuid primary key default gen_random_uuid(),title text not null,body text not null,priority text not null default 'normal' check(priority in ('normal','important')),created_by uuid not null default auth.uid(),created_at timestamptz not null default now());
create table if not exists public.join_applications(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid(),name text not null,discord text not null,steam text not null,experience text not null,message text not null,status text not null default 'pending' check(status in ('pending','approved','rejected')),created_at timestamptz not null default now());

alter table public.trips enable row level security;
alter table public.event_participations enable row level security;
alter table public.wallet_entries enable row level security;
alter table public.company_notices enable row level security;
alter table public.join_applications enable row level security;

-- Leituras gerais para dados de jogo. Candidaturas visíveis apenas ao autor e à gerência.
DROP POLICY IF EXISTS "trips_read" ON public.trips;
create policy "trips_read" on public.trips for select to authenticated using(true);
DROP POLICY IF EXISTS "events_read" ON public.event_participations;
create policy "events_read" on public.event_participations for select to authenticated using(true);
DROP POLICY IF EXISTS "wallet_read" ON public.wallet_entries;
create policy "wallet_read" on public.wallet_entries for select to authenticated using(true);
DROP POLICY IF EXISTS "notices_read" ON public.company_notices;
create policy "notices_read" on public.company_notices for select to authenticated using(true);
DROP POLICY IF EXISTS "applications_read" ON public.join_applications;
create policy "applications_read" on public.join_applications for select to authenticated using(user_id=(select auth.uid()) or (select public.raviera_is_manager()));

DROP POLICY IF EXISTS "trips_submit" ON public.trips;
create policy "trips_submit" on public.trips for insert to authenticated with check(created_by=(select auth.uid()) and status='pending');
DROP POLICY IF EXISTS "events_submit" ON public.event_participations;
create policy "events_submit" on public.event_participations for insert to authenticated with check(created_by=(select auth.uid()) and status='pending');
DROP POLICY IF EXISTS "applications_submit" ON public.join_applications;
create policy "applications_submit" on public.join_applications for insert to authenticated with check(user_id=(select auth.uid()) and status='pending');
DROP POLICY IF EXISTS "wallet_manage_insert" ON public.wallet_entries;
create policy "wallet_manage_insert" on public.wallet_entries for insert to authenticated with check((select public.raviera_is_manager()));
DROP POLICY IF EXISTS "notices_manage_insert" ON public.company_notices;
create policy "notices_manage_insert" on public.company_notices for insert to authenticated with check((select public.raviera_is_manager()) and created_by=(select auth.uid()));

DROP POLICY IF EXISTS "trips_manage" ON public.trips;
create policy "trips_manage" on public.trips for update to authenticated using((select public.raviera_is_manager())) with check((select public.raviera_is_manager()));
DROP POLICY IF EXISTS "events_manage" ON public.event_participations;
create policy "events_manage" on public.event_participations for update to authenticated using((select public.raviera_is_manager())) with check((select public.raviera_is_manager()));
DROP POLICY IF EXISTS "applications_manage" ON public.join_applications;
create policy "applications_manage" on public.join_applications for update to authenticated using((select public.raviera_is_manager())) with check((select public.raviera_is_manager()));
DROP POLICY IF EXISTS "wallet_manage_delete" ON public.wallet_entries;
create policy "wallet_manage_delete" on public.wallet_entries for delete to authenticated using((select public.raviera_is_manager()));
DROP POLICY IF EXISTS "notices_manage_delete" ON public.company_notices;
create policy "notices_manage_delete" on public.company_notices for delete to authenticated using((select public.raviera_is_manager()));

-- Impede que gerentes ou outros usuários modifiquem campos além do status nos registros pendentes.
create or replace function public.raviera_review_only() returns trigger language plpgsql as $$
begin
 if NEW.id is distinct from OLD.id or NEW.created_at is distinct from OLD.created_at then raise exception 'Identificação não pode ser alterada'; end if;
 if TG_TABLE_NAME in ('trips','event_participations') then
  if NEW.driver_id is distinct from OLD.driver_id or NEW.created_by is distinct from OLD.created_by then raise exception 'Motorista e autor não podem ser alterados'; end if;
 end if;
 if TG_TABLE_NAME='trips' and row(NEW.trip_date,NEW.origin,NEW.destination,NEW.distance_km,NEW.notes) is distinct from row(OLD.trip_date,OLD.origin,OLD.destination,OLD.distance_km,OLD.notes) then raise exception 'Apenas status pode ser alterado'; end if;
 if TG_TABLE_NAME='event_participations' and NEW.convoy_id is distinct from OLD.convoy_id then raise exception 'Apenas status pode ser alterado'; end if;
 if TG_TABLE_NAME='join_applications' and row(NEW.user_id,NEW.name,NEW.discord,NEW.steam,NEW.experience,NEW.message) is distinct from row(OLD.user_id,OLD.name,OLD.discord,OLD.steam,OLD.experience,OLD.message) then raise exception 'Apenas status pode ser alterado'; end if;
 return NEW;
end; $$;
DROP TRIGGER IF EXISTS trips_review_only ON public.trips;
create trigger trips_review_only before update on public.trips for each row execute function public.raviera_review_only();
DROP TRIGGER IF EXISTS events_review_only ON public.event_participations;
create trigger events_review_only before update on public.event_participations for each row execute function public.raviera_review_only();
DROP TRIGGER IF EXISTS applications_review_only ON public.join_applications;
create trigger applications_review_only before update on public.join_applications for each row execute function public.raviera_review_only();

create index if not exists trips_driver_date_idx on public.trips(driver_id,trip_date);
create index if not exists events_driver_idx on public.event_participations(driver_id);
create index if not exists wallet_driver_idx on public.wallet_entries(driver_id);
create index if not exists applications_user_idx on public.join_applications(user_id);

COMMIT;

-- ETAPA 4: ULTIMATE, SUPORTE, CONQUISTAS E AUDITORIA
BEGIN;
-- RAVIERA ULTIMATE - MIGRAÇÃO ADITIVA (NÃO RECRIA TABELAS EXISTENTES)
-- Faça backup antes. Execute como proprietário do projeto no Supabase SQL Editor.
create extension if not exists pgcrypto;
-- Usa a função raviera_is_manager já criada em raviera_modulos.sql.
create table if not exists public.support_tickets (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references auth.users(id),
 subject text not null check(length(subject) between 3 and 120), category text not null default 'general' check(category in ('general','telemetry','registration','trip')),
 message text not null check(length(message) between 10 and 3000), status text not null default 'open' check(status in ('open','in_progress','closed')),
 created_at timestamptz not null default now());
create table if not exists public.driver_preferences (
 user_id uuid primary key references auth.users(id), driver_id uuid unique references public.drivers(id),
 division text not null default 'group' check(division in ('group','agro','racing')),
 theme text not null default 'dark' check(theme in ('dark','light')),
 created_at timestamptz not null default now());
create table if not exists public.driver_achievements (
 id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.drivers(id),
 code text not null,awarded_by uuid references auth.users(id),created_at timestamptz not null default now(),
 unique(driver_id,code));
create table if not exists public.driver_notifications (
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id),
 notice_id uuid not null references public.company_notices(id) on delete cascade,read_at timestamptz,
 created_at timestamptz not null default now(),unique(user_id,notice_id));
create table if not exists public.management_audit (
 id uuid primary key default gen_random_uuid(),actor_id uuid not null default auth.uid() references auth.users(id),
 action text not null,details text not null default '',created_at timestamptz not null default now());
create index if not exists support_tickets_user_idx on public.support_tickets(user_id,created_at desc);
create index if not exists audit_created_idx on public.management_audit(created_at desc);
create index if not exists notifications_user_idx on public.driver_notifications(user_id);
-- RLS (default deny for unauthenticated users)
alter table public.support_tickets enable row level security;
alter table public.driver_preferences enable row level security;
alter table public.driver_achievements enable row level security;
alter table public.driver_notifications enable row level security;
alter table public.management_audit enable row level security;
-- Idempotent policy creation; do not drop other policies.
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_select') then
  create policy rv_ticket_select on public.support_tickets for select to authenticated using(user_id=(select auth.uid()) or (select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_insert') then
  create policy rv_ticket_insert on public.support_tickets for insert to authenticated with check(user_id=(select auth.uid()) and status='open'); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_update') then
  create policy rv_ticket_update on public.support_tickets for update to authenticated using((select public.raviera_is_manager())) with check((select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_select') then
  create policy rv_prefs_select on public.driver_preferences for select to authenticated using(user_id=(select auth.uid()) or (select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_insert') then
  create policy rv_prefs_insert on public.driver_preferences for insert to authenticated with check(user_id=(select auth.uid()) and driver_id is null); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_update') then
  create policy rv_prefs_update on public.driver_preferences for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()) and driver_id is null); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_achievements' and policyname='rv_achievements_select') then
  create policy rv_achievements_select on public.driver_achievements for select to authenticated using(true); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_achievements' and policyname='rv_achievements_insert') then
  create policy rv_achievements_insert on public.driver_achievements for insert to authenticated with check((select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_select') then
  create policy rv_notifications_select on public.driver_notifications for select to authenticated using(user_id=(select auth.uid())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_insert') then
  create policy rv_notifications_insert on public.driver_notifications for insert to authenticated with check(user_id=(select auth.uid()) and notice_id in (select id from public.company_notices)); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_update') then
  create policy rv_notifications_update on public.driver_notifications for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()) and driver_id is null); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='management_audit' and policyname='rv_audit_select') then
  create policy rv_audit_select on public.management_audit for select to authenticated using((select public.raviera_is_manager())); end if;
 end $$;
-- Audit events are server-generated on updates to approvals (not editable by clients).
-- join_applications does not have created_by; use user_id for fallback
create or replace function public.rv_audit_status_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status then
  insert into public.management_audit(actor_id,action,details) values(auth.uid(),TG_TABLE_NAME||'_status',old.id::text||': '||old.status||' -> '||new.status);
 end if;
 return new;
end $$;
drop trigger if exists rv_audit_trips on public.trips;
create trigger rv_audit_trips after update of status on public.trips for each row execute function public.rv_audit_status_change();
drop trigger if exists rv_audit_events on public.event_participations;
create trigger rv_audit_events after update of status on public.event_participations for each row execute function public.rv_audit_status_change();
drop trigger if exists rv_audit_applications on public.join_applications;
create trigger rv_audit_applications after update of status on public.join_applications for each row execute function public.rv_audit_status_change();
COMMIT;

-- CONFERÊNCIA (retorna as tabelas criadas):
SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;
-- PARA PROMOVER UMA CONTA DE TESTE (depois de criá-la em Authentication > Users):
-- UPDATE public.user_profiles SET role='admin' WHERE id='UUID-DO-USUARIO-AQUI';
-- NUNCA coloque comandos de promoção a admin no JavaScript público do GitHub.

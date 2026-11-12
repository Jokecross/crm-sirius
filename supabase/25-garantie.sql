-- =====================================================================
--  Sirius — la garantie « Premier client en 7 jours » qui tient la route
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  1. Contrats : version 1 = signés avant ce fichier (sans conditions de
--     suivi), version 2 = les suivants, avec les conditions.
--  2. Visionnage : le lecteur Loom dit à la page chaque seconde lue. La base
--     garde une case par seconde de la vidéo ; avancer ne compte pas. À 95 %
--     regardés, la vidéo est cochée toute seule.
--  3. Garantie : à la fin des 7 jours, l'élève répond « as-tu trouvé ton
--     premier client ? ». S'il dit non et remplit les conditions, il peut
--     demander son remboursement ; l'équipe voit tout et coche « remboursé ».
--
--  Conditions (contrat version 2) : 7 captures du workshop (jours 1 à 7)
--  et toutes les vidéos de sa formule regardées à 95 % au moins.
-- =====================================================================

-- 1. La version des contrats.
alter table public.contrats add column if not exists version int;
update public.contrats set version = 1 where version is null;
alter table public.contrats alter column version set default 2;
alter table public.contrats alter column version set not null;

create or replace function public.contrat_lire(p_token uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'formule',     p.label,
    'date_entree', (i.created_at at time zone 'Europe/Paris')::date,
    'pour',        i.label,
    'signe',       c.signe_at is not null,
    'version',     coalesce(c.version, 2),
    'prenom',      c.prenom,
    'nom',         c.nom,
    'email',       c.email,
    'telephone',   c.telephone,
    'signature',   c.signature,
    'signe_at',    c.signe_at
  )
  from invites i
  join plans p on p.code = i.plan_code
  left join contrats c on c.token = i.token
  where i.token = p_token
    and i.created_at > now() - interval '120 days';
$$;

-- 2. Le visionnage, seconde par seconde.
create table if not exists public.visionnages (
  member_id   uuid   not null references public.members(id) on delete cascade,
  lesson_id   bigint not null references public.lessons(id) on delete cascade,
  duree       int    not null check (duree between 1 and 14400),
  vues        text   not null,                 -- une case par seconde : 0 ou 1
  pourcentage numeric(5,1) not null default 0,
  maj         timestamptz not null default now(),
  primary key (member_id, lesson_id)
);

alter table public.visionnages enable row level security;
revoke all on public.visionnages from anon, authenticated;
grant select on public.visionnages to authenticated;
drop policy if exists "lecture des visionnages" on public.visionnages;
create policy "lecture des visionnages" on public.visionnages
  for select to authenticated
  using (member_id = auth.uid() or public.is_equipe(auth.uid()));

create or replace function public.visionnage_noter(p_lesson bigint, p_duree int, p_secondes int[])
returns numeric
language plpgsql security definer set search_path = public
as $$
declare
  moi     uuid := auth.uid();
  v_duree int  := least(greatest(coalesce(p_duree, 0), 1), 14400);
  v_vues  text;
  v_pct   numeric;
  s       int;
begin
  if moi is null or not exists (select 1 from members where id = moi) then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  if not public.is_module_unlocked(moi, (select module_id from lessons where id = p_lesson)) then
    raise exception 'Vidéo fermée' using errcode = '42501';
  end if;
  select vues into v_vues from visionnages where member_id = moi and lesson_id = p_lesson for update;
  if v_vues is null then v_vues := repeat('0', v_duree);
  elsif length(v_vues) < v_duree then v_vues := rpad(v_vues, v_duree, '0');
  end if;
  v_duree := length(v_vues);
  foreach s in array coalesce(p_secondes[1:600], '{}') loop
    if s >= 0 and s < v_duree then
      v_vues := overlay(v_vues placing '1' from s + 1 for 1);
    end if;
  end loop;
  v_pct := round((length(v_vues) - length(replace(v_vues, '1', ''))) * 100.0 / v_duree, 1);
  insert into visionnages (member_id, lesson_id, duree, vues, pourcentage, maj)
  values (moi, p_lesson, v_duree, v_vues, v_pct, now())
  on conflict (member_id, lesson_id) do update
    set duree = excluded.duree, vues = excluded.vues, pourcentage = excluded.pourcentage, maj = now();
  if v_pct >= 95 then
    insert into lesson_progress (member_id, lesson_id) values (moi, p_lesson) on conflict do nothing;
  end if;
  return v_pct;
end;
$$;

revoke all on function public.visionnage_noter(bigint, int, int[]) from public, anon;
grant execute on function public.visionnage_noter(bigint, int, int[]) to authenticated;

-- 3. La garantie.
create table if not exists public.garanties (
  member_id      uuid primary key references public.members(id) on delete cascade,
  premier_client boolean,
  repondu_at     timestamptz,
  demande_at     timestamptz,
  rembourse_at   timestamptz,
  rembourse_par  uuid references public.members(id),
  note           text
);
alter table public.garanties enable row level security;
revoke all on public.garanties from anon, authenticated;
grant select on public.garanties to authenticated;
drop policy if exists "lecture des garanties" on public.garanties;
create policy "lecture des garanties" on public.garanties
  for select to authenticated
  using (member_id = auth.uid() or public.is_equipe(auth.uid()));

-- L'état complet de la garantie d'un élève : contrat, avancement, réponse,
-- demande, et le verdict. L'élève ne voit que le sien, l'équipe tous.
create or replace function public.garantie_etat(p_member uuid default null)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  m        uuid := coalesce(p_member, auth.uid());
  v_plan   text;
  v_c      record;
  v_g      record;
  v_entree date;
  v_ws     int;
  v_total  int;
  v_vues   int;
  v_fin    date;
  v_limite date;
  v_raison text;
begin
  if m is null or (m <> auth.uid() and not public.is_equipe(auth.uid())) then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  select plan_code into v_plan from members where id = m;
  select c.version, c.signe_at, (i.created_at at time zone 'Europe/Paris')::date as entree, i.token
    into v_c
    from invites i join contrats c on c.token = i.token
   where i.used_by = m
   order by c.signe_at desc limit 1;
  select * into v_g from garanties where member_id = m;

  select count(distinct jour) into v_ws from workshop_captures where member_id = m and jour between 1 and 7;
  select count(*), count(*) filter (where coalesce(vi.pourcentage, 0) >= 95)
    into v_total, v_vues
    from plan_modules pm
    join modules mo on mo.id = pm.module_id and not mo.is_bonus
    join lessons l on l.module_id = mo.id
    left join visionnages vi on vi.lesson_id = l.id and vi.member_id = m
   where pm.plan_code = v_plan;

  v_entree := v_c.entree;
  v_fin    := v_entree + 7;
  v_limite := v_entree + 30;
  v_raison := case
    when v_c.signe_at is null then 'Pas de contrat signé'
    when v_g.rembourse_at is not null then 'Déjà remboursé'
    when coalesce(v_g.premier_client, false) then 'A trouvé son premier client'
    when (now() at time zone 'Europe/Paris')::date < v_fin then 'Les 7 jours ne sont pas finis'
    when (now() at time zone 'Europe/Paris')::date > v_limite and v_g.demande_at is null then 'Délai de 30 jours dépassé'
    when v_c.version >= 2 and v_ws < 7 then format('Workshop incomplet : %s capture(s) sur 7', v_ws)
    when v_c.version >= 2 and v_vues < v_total then format('Vidéos incomplètes : %s sur %s', v_vues, v_total)
    else null end;

  return json_build_object(
    'contrat_signe',   v_c.signe_at is not null,
    'version',         v_c.version,
    'date_entree',     v_entree,
    'fin_7_jours',     v_fin,
    'date_limite',     v_limite,
    'workshop',        v_ws,
    'videos_vues',     v_vues,
    'videos_total',    v_total,
    'premier_client',  v_g.premier_client,
    'repondu_at',      v_g.repondu_at,
    'demande_at',      v_g.demande_at,
    'rembourse_at',    v_g.rembourse_at,
    'eligible',        v_raison is null,
    'raison',          v_raison
  );
end;
$$;

create or replace function public.garantie_repondre(p_premier_client boolean)
returns json
language plpgsql security definer set search_path = public
as $$
declare e json;
begin
  e := public.garantie_etat(auth.uid());
  if not (e->>'contrat_signe')::boolean then raise exception 'Pas de contrat signé' using errcode = '42501'; end if;
  if (now() at time zone 'Europe/Paris')::date < (e->>'fin_7_jours')::date then
    raise exception 'Les 7 jours ne sont pas finis' using errcode = '22023';
  end if;
  insert into garanties (member_id, premier_client, repondu_at) values (auth.uid(), p_premier_client, now())
  on conflict (member_id) do update set premier_client = excluded.premier_client, repondu_at = now()
    where garanties.demande_at is null and garanties.rembourse_at is null;
  return public.garantie_etat(auth.uid());
end;
$$;

create or replace function public.garantie_demander()
returns json
language plpgsql security definer set search_path = public
as $$
declare e json;
begin
  e := public.garantie_etat(auth.uid());
  if (e->>'premier_client') is null then raise exception 'Réponds d''abord à la question' using errcode = '22023'; end if;
  if not (e->>'eligible')::boolean then raise exception '%', e->>'raison' using errcode = '22023'; end if;
  update garanties set demande_at = coalesce(demande_at, now()) where member_id = auth.uid();
  return public.garantie_etat(auth.uid());
end;
$$;

create or replace function public.garantie_rembourser(p_member uuid, p_fait boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'Réservé aux administrateurs' using errcode = '42501'; end if;
  insert into garanties (member_id, rembourse_at, rembourse_par) values (p_member, case when p_fait then now() end, case when p_fait then auth.uid() end)
  on conflict (member_id) do update
    set rembourse_at = case when p_fait then now() end, rembourse_par = case when p_fait then auth.uid() end;
end;
$$;

-- Le suivi de l'équipe : tous les élèves qui ont signé un contrat.
create or replace function public.garanties_suivi()
returns json
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_equipe(auth.uid()) then raise exception 'Réservé à l''équipe' using errcode = '42501'; end if;
  return coalesce((
    select json_agg(x order by (x->>'date_entree') desc) from (
      select (public.garantie_etat(m.id)::jsonb || jsonb_build_object(
               'member_id', m.id, 'prenom', m.first_name, 'nom', m.last_name, 'email', m.email,
               'formule', p.label,
               'setter', (select concat_ws(' ', s.first_name, s.last_name) from members s where s.id = i.created_by)))::json as x
        from members m
        join invites i on i.used_by = m.id
        join contrats c on c.token = i.token
        left join plans p on p.code = m.plan_code
       where m.role = 'member'
    ) t
  ), '[]'::json);
end;
$$;

revoke all on function public.garantie_etat(uuid) from public, anon;
revoke all on function public.garantie_repondre(boolean) from public, anon;
revoke all on function public.garantie_demander() from public, anon;
revoke all on function public.garantie_rembourser(uuid, boolean) from public, anon;
revoke all on function public.garanties_suivi() from public, anon;
grant execute on function public.garantie_etat(uuid) to authenticated;
grant execute on function public.garantie_repondre(boolean) to authenticated;
grant execute on function public.garantie_demander() to authenticated;
grant execute on function public.garantie_rembourser(uuid, boolean) to authenticated;
grant execute on function public.garanties_suivi() to authenticated;

notify pgrst, 'reload schema';

-- Vérification : les contrats déjà signés passent en version 1.
select version, count(*) from public.contrats group by version;

-- =====================================================================
--  Sirius — l'équipe Skool réserve ses appels sur un calendrier
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS INSTALLATION.sql (il en fait aussi partie, section I).
--
--  Chaque setter Skool a un lien à lui : <page de vente>/rdv/<code>.
--  La personne qui l'ouvre voit les créneaux libres du setter, tirés de
--  ses dispos (onglet Dispos du CRM), en choisit un et laisse ses
--  coordonnées. Le lead arrive dans l'équipe Skool, déjà attribué au
--  setter, avec l'heure de l'appel.
--
--  Le public ne lit rien et n'écrit rien directement : il passe par deux
--  fonctions, qui ne renvoient que le prénom du setter et des heures, et
--  qui vérifient le créneau au moment de réserver (deux personnes sur le
--  même créneau : la seconde reçoit « ce créneau vient d'être pris »).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Les réglages : durée d'un appel, préavis, jusqu'où on peut réserver
-- ---------------------------------------------------------------------
alter table public.crm_reglages
  add column if not exists rdv_duree_min     int not null default 15,
  add column if not exists rdv_delai_min     int not null default 60,
  add column if not exists rdv_horizon_jours int not null default 14;

alter table public.crm_reglages drop constraint if exists crm_reglages_rdv_check;
alter table public.crm_reglages add constraint crm_reglages_rdv_check check (
  rdv_duree_min between 10 and 180
  and rdv_delai_min between 0 and 2880
  and rdv_horizon_jours between 1 and 60
);

comment on column public.crm_reglages.rdv_duree_min is 'Durée d''un appel réservé, en minutes. Les créneaux sont découpés à ce pas.';
comment on column public.crm_reglages.rdv_delai_min is 'Préavis : on ne peut pas réserver un créneau qui commence dans moins de N minutes.';
comment on column public.crm_reglages.rdv_horizon_jours is 'On ne voit les créneaux que sur les N prochains jours.';

-- ---------------------------------------------------------------------
-- 2. Le lien de chaque setter : /rdv/<code>
-- ---------------------------------------------------------------------
alter table public.staff add column if not exists rdv_code text;

alter table public.staff drop constraint if exists staff_rdv_code_format;
alter table public.staff add constraint staff_rdv_code_format
  check (rdv_code is null or rdv_code ~ '^[a-z0-9-]{2,40}$');

create unique index if not exists staff_rdv_code_idx on public.staff (rdv_code)
  where rdv_code is not null;

comment on column public.staff.rdv_code is
  'Fin du lien de réservation du setter (/rdv/<code>). Tiré du prénom, unique. Un admin peut le changer.';

-- Le code se tire du prénom : « Mathéo » → mateo, puis mateo2 s'il est pris.
create or replace function public.code_rdv_libre(p_prenom text, p_user uuid)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  base text;
  code text;
  n    int := 1;
begin
  base := lower(regexp_replace(
    translate(coalesce(p_prenom, ''),
      'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
      'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY'),
    '[^a-zA-Z0-9]+', '', 'g'));
  if char_length(base) < 2 then base := 'setter'; end if;
  base := left(base, 36);
  code := base;
  while exists (select 1 from public.staff where rdv_code = code and user_id <> p_user) loop
    n := n + 1;
    code := base || n;
  end loop;
  return code;
end;
$$;

create or replace function public.staff_rdv_code()
returns trigger language plpgsql as $$
begin
  if new.rdv_code is null or btrim(new.rdv_code) = '' then
    new.rdv_code := public.code_rdv_libre(new.first_name, new.user_id);
  else
    new.rdv_code := lower(btrim(new.rdv_code));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_staff_rdv_code on public.staff;
create trigger trg_staff_rdv_code
  before insert or update of rdv_code, first_name on public.staff
  for each row
  when (new.rdv_code is null or btrim(new.rdv_code) = '' or new.rdv_code <> lower(btrim(new.rdv_code)))
  execute function public.staff_rdv_code();

-- Les comptes déjà créés reçoivent leur code, un par un (deux Thomas
-- dans la même requête prendraient sinon le même).
do $$
declare s record;
begin
  for s in select user_id, first_name from public.staff where rdv_code is null order by created_at loop
    update public.staff set rdv_code = public.code_rdv_libre(s.first_name, s.user_id)
    where user_id = s.user_id;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Le rendez-vous, sur le lead
-- ---------------------------------------------------------------------
alter table public.leads
  add column if not exists rdv_at         timestamptz,   -- début de l'appel réservé
  add column if not exists rdv_fin_at     timestamptz,
  add column if not exists rdv_reserve_at timestamptz,   -- quand la personne a réservé
  add column if not exists rdv_annule_at  timestamptz;   -- annulé depuis le CRM : le créneau se libère

comment on column public.leads.rdv_at is
  'Appel réservé par le lead sur le calendrier de son setter (équipe Skool).';

-- Deux rendez-vous actifs au même moment chez le même setter : impossible.
create unique index if not exists leads_rdv_unique on public.leads (setter_id, rdv_at)
  where rdv_at is not null and rdv_annule_at is null;
create index if not exists leads_rdv_idx on public.leads (equipe, rdv_at)
  where rdv_at is not null;

-- ---------------------------------------------------------------------
-- 4. Les créneaux libres d'un setter
-- ---------------------------------------------------------------------
-- Ses dispos à venir, découpées au pas de la durée d'un appel, moins ce
-- qui est déjà réservé, le préavis et l'horizon. Interne : le public
-- passe par rdv_calendrier().
create or replace function public.rdv_creneaux_setter(p_setter uuid)
returns table (debut timestamptz, fin timestamptz)
language sql stable security definer set search_path = public
as $$
  with r as (
    select make_interval(mins => rdv_duree_min)     as duree,
           make_interval(mins => rdv_delai_min)     as delai,
           make_interval(days => rdv_horizon_jours) as horizon
    from public.crm_reglages where id = 1
  ),
  plages as (
    select d.debut_at, d.fin_at
    from public.dispos d, r
    where d.setter_id = p_setter
      and d.supprime_at is null
      and d.fin_at > now()
      and d.debut_at < now() + r.horizon
  ),
  pas as (
    select g as debut, g + r.duree as fin
    from plages p, r, generate_series(p.debut_at, p.fin_at - r.duree, r.duree) g
  )
  select distinct pas.debut, pas.fin
  from pas, r
  where pas.debut >= now() + r.delai
    and pas.debut <  now() + r.horizon
    and not exists (
      select 1 from public.leads l
      where l.setter_id = p_setter
        and l.rdv_at is not null and l.rdv_annule_at is null
        and l.rdv_at < pas.fin
        and coalesce(l.rdv_fin_at, l.rdv_at + r.duree) > pas.debut)
  order by 1;
$$;

revoke all on function public.rdv_creneaux_setter(uuid) from public, anon, authenticated;

-- Le setter derrière un lien : actif et dans l'équipe Skool.
create or replace function public.rdv_setter(p_code text)
returns public.staff
language sql stable security definer set search_path = public
as $$
  select s.* from public.staff s
  where s.rdv_code = lower(btrim(p_code))
    and s.actif
    and 'skool' = any(coalesce(s.equipes, array[s.equipe]))
  limit 1;
$$;

revoke all on function public.rdv_setter(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Ce que voit le public : le prénom du setter et ses créneaux libres
-- ---------------------------------------------------------------------
create or replace function public.rdv_calendrier(p_code text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  s public.staff;
  r public.crm_reglages;
begin
  s := public.rdv_setter(p_code);
  if s.user_id is null then return null; end if;
  select * into r from public.crm_reglages where id = 1;
  return jsonb_build_object(
    'prenom',   s.first_name,
    'duree',    r.rdv_duree_min,
    'creneaux', coalesce((select jsonb_agg(c.debut order by c.debut)
                          from public.rdv_creneaux_setter(s.user_id) c), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Réserver
-- ---------------------------------------------------------------------
create or replace function public.rdv_reserver(
  p_code      text,
  p_debut     timestamptz,
  p_prenom    text,
  p_nom       text,
  p_email     text,
  p_telephone text,
  p_page_url  text default null,
  p_source    text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  s public.staff;
  r public.crm_reglages;
  tel text := regexp_replace(coalesce(p_telephone, ''), '[^0-9+]', '', 'g');
begin
  s := public.rdv_setter(p_code);
  if s.user_id is null then
    raise exception 'Ce lien de réservation n''existe plus.' using errcode = 'P0002';
  end if;

  -- Une réservation à la fois par setter : la vérification du créneau et
  -- l'insertion ne peuvent pas se croiser avec celles d'un autre visiteur.
  perform pg_advisory_xact_lock(hashtext('rdv:' || s.user_id::text));

  if not exists (select 1 from public.rdv_creneaux_setter(s.user_id) c where c.debut = p_debut) then
    raise exception 'Ce créneau vient d''être pris. Choisis-en un autre.' using errcode = 'P0001';
  end if;

  -- Un même numéro n'a qu'un appel à venir chez un même setter.
  if exists (select 1 from public.leads
             where setter_id = s.user_id and phone = tel
               and rdv_at > now() and rdv_annule_at is null) then
    raise exception 'Tu as déjà un appel réservé avec %. On te contacte à l''heure prévue.', s.first_name
      using errcode = 'P0001';
  end if;

  select * into r from public.crm_reglages where id = 1;

  insert into public.leads (
    first_name, last_name, email, phone, page_url, source,
    equipe, vivier, status, setter_id,
    rdv_at, rdv_fin_at, rdv_reserve_at
  ) values (
    btrim(p_prenom), btrim(p_nom), lower(btrim(p_email)), tel,
    left(p_page_url, 300), left(p_source, 300),
    'skool', 'formulaire', 'nouveau', s.user_id,
    p_debut, p_debut + make_interval(mins => r.rdv_duree_min), now()
  );

  return jsonb_build_object('ok', true, 'prenom', s.first_name,
                            'debut', p_debut, 'duree', r.rdv_duree_min);
end;
$$;

revoke all on function public.rdv_calendrier(text) from public;
revoke all on function public.rdv_reserver(text, timestamptz, text, text, text, text, text, text) from public;
grant execute on function public.rdv_calendrier(text) to anon, authenticated;
grant execute on function public.rdv_reserver(text, timestamptz, text, text, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. « Ta situation aujourd'hui », demandée par le formulaire de la page
-- ---------------------------------------------------------------------
alter table public.leads add column if not exists situation text;
alter table public.leads drop constraint if exists leads_situation_len;
alter table public.leads add constraint leads_situation_len
  check (situation is null or char_length(situation) <= 40);
comment on column public.leads.situation is
  'Salarié, Étudiant, Sans emploi, Indépendant ou Autre : choisi dans le formulaire de la page de vente.';

-- Vérification : le lien de chaque setter Skool.
select first_name, rdv_code
from public.staff
where 'skool' = any(coalesce(equipes, array[equipe]))
order by first_name;

-- ════════════════════════════════════════════════════════════
-- Sirius — INSTALLATION COMPLÈTE DE LA BASE
-- Généré le 29/10/2026 (repris de Marcuus, deux équipes : Base44 et Skool)
--
-- Une seule base pour trois outils :
--   A. la page de vente   → table leads (le formulaire n'a que le droit d'insérer)
--   B. le CRM des setters → staff, statuts, commissions, factures, appels
--   C. l'espace membre    → membres, modules, invitations, workshop 7 jours
--   Z. l'équipe Skool     → calendrier de chaque setter et lien de réservation
--
-- Colle TOUT ce fichier dans Supabase → SQL Editor → Run.
-- Projet : le projet Supabase de Sirius (vérifie l'URL avant de lancer).
--
-- À faire ensuite, à la main :
--   1. Authentication → Sign In / Providers → désactiver « Allow new users to sign up ».
--   2. Créer les comptes de l'équipe : CRM Sirius/scripts/creer-comptes.mjs.
--
-- Rejouable : relancer ce fichier ne casse rien.
-- ════════════════════════════════════════════════════════════


-- ╔══════════════════════════════════════════════════════════
-- ║  A. Page de vente : table des leads
-- ╚══════════════════════════════════════════════════════════
-- ============================================================
--  Page de vente Sirius (premier client en 7 jours) — table des leads
--  À exécuter dans Supabase → SQL Editor → New query → Run
--  (sur le projet Supabase de Sirius, pas sur un autre)
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Statut de traitement par les setters ----------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'lead_status') then
    create type lead_status as enum (
      'nouveau',      -- vient d'arriver, personne ne l'a encore pris
      'a_rappeler',   -- tentative faite, pas joint
      'appele',       -- setter a eu la personne au téléphone
      'rdv_pris',     -- appel découverte calé
      'perdu'         -- injoignable ou pas qualifié
    );
  end if;
end $$;

-- ---------- Table ----------
create table if not exists public.leads (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),

  first_name   text not null,
  last_name    text not null,
  email        text not null,
  phone        text not null,

  page_url     text,
  source       text,          -- canal de tracking (?src=) ou referrer

  status       lead_status not null default 'nouveau',
  called_at    timestamptz,   -- quand un setter a appelé
  notes        text,          -- compte rendu de l'appel

  constraint leads_first_name_len check (char_length(first_name) between 1 and 80),
  constraint leads_last_name_len  check (char_length(last_name)  between 1 and 80),
  constraint leads_email_format   check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$'),
  constraint leads_email_len      check (char_length(email) <= 160),
  constraint leads_phone_len      check (char_length(phone) between 9 and 40),
  constraint leads_page_url_len   check (page_url is null or char_length(page_url) <= 300),
  constraint leads_source_len     check (source   is null or char_length(source)   <= 300)
);

create index if not exists leads_created_at_idx on public.leads (created_at desc);
create index if not exists leads_status_idx     on public.leads (status);

-- ============================================================
--  SÉCURITÉ (RLS)
--  La clé "anon" est publique : elle est dans le code de la page.
--  Le public peut donc UNIQUEMENT insérer. Aucune lecture, aucune
--  modification, aucune suppression — sinon n'importe qui pourrait
--  aspirer la liste des leads avec cette clé.
--  La lecture se fait via le dashboard Supabase ou avec la clé
--  service_role (jamais côté navigateur).
-- ============================================================
alter table public.leads enable row level security;
alter table public.leads force row level security;

drop policy if exists "public peut deposer un lead" on public.leads;
create policy "public peut deposer un lead"
  on public.leads
  for insert
  to anon
  with check (
    -- un formulaire ne doit jamais pouvoir préremplir le suivi interne
    status = 'nouveau'
    and called_at is null
    and notes is null
  );

-- Aucune policy select/update/delete pour anon : tout le reste est refusé.

-- Ceinture et bretelles : Supabase accorde par défaut tous les droits
-- sur le schéma public aux rôles anon et authenticated. On ne laisse à
-- anon que l'insertion, la RLS faisant le reste.
revoke all on public.leads from anon;
grant insert on public.leads to anon;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 01-crm-schema.sql
-- ╚══════════════════════════════════════════════════════════
-- ============================================================
--  CRM Ecom Boss — socle base de données
--  À exécuter dans Supabase → SQL Editor → New query → Run
--
--  Ce script :
--    1. crée la table `staff` (qui a le droit d'entrer)
--    2. bascule les statuts sur le vocabulaire de l'équipe
--    3. ajoute les colonnes de suivi commercial
--    4. calcule la commission automatiquement
--    5. pose les règles d'accès (RLS)
-- ============================================================

-- ------------------------------------------------------------
-- 1. STAFF — les comptes autorisés
-- ------------------------------------------------------------
create table if not exists public.staff (
  user_id    uuid primary key references auth.users on delete cascade,
  first_name text not null,
  last_name  text,
  role       text not null default 'setter' check (role in ('setter', 'admin')),
  actif      boolean not null default true,
  created_at timestamptz not null default now()
);

-- Fonction utilitaire : « la personne connectée fait-elle partie de l'équipe ? »
-- security definer = elle lit `staff` sans repasser par RLS, ce qui évite
-- une récursion infinie dans les policies.
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin'
  );
$$;

alter table public.staff enable row level security;

drop policy if exists "staff se voit" on public.staff;
create policy "staff se voit"
  on public.staff for select
  to authenticated
  using (public.is_staff());

drop policy if exists "admin gere le staff" on public.staff;
create policy "admin gere le staff"
  on public.staff for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- 2. STATUTS — vocabulaire de l'équipe
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'lead_statut') then
    create type lead_statut as enum (
      'nouveau',
      'follow_up',
      'monthly',
      'yearly',
      'ghosted',
      'time_waster',
      'pas_de_reponse',
      'faux_numero'
    );
  end if;
end $$;

-- La policy d'insertion publique et la vue de la première version dépendent
-- de la colonne : on les retire le temps de changer son type, puis on remet.
drop policy if exists "public peut deposer un lead" on public.leads;
drop view   if exists public.leads_a_rappeler;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'leads'
      and column_name = 'status' and udt_name = 'lead_status'
  ) then
    alter table public.leads alter column status drop default;
    alter table public.leads
      alter column status type lead_statut
      using (case status::text
               when 'nouveau'    then 'nouveau'
               when 'a_rappeler' then 'follow_up'
               when 'appele'     then 'follow_up'
               when 'rdv_pris'   then 'monthly'
               when 'perdu'      then 'ghosted'
               else 'nouveau'
             end)::lead_statut;
    alter table public.leads alter column status set default 'nouveau';
    drop type if exists lead_status;
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. COLONNES DE SUIVI
-- ------------------------------------------------------------
alter table public.leads add column if not exists setter_id     uuid references auth.users on delete set null;
alter table public.leads add column if not exists follow_up_at  timestamptz;
alter table public.leads add column if not exists dials         integer not null default 0;
alter table public.leads add column if not exists montant       numeric(10,2) not null default 200;
alter table public.leads add column if not exists cash_collecte numeric(10,2) not null default 0;

alter table public.leads drop constraint if exists leads_dials_positif;
alter table public.leads add constraint leads_dials_positif check (dials >= 0);

-- ------------------------------------------------------------
-- 4. COMMISSION — 10 % sur mensuel, 15 % sur annuel
--    (calculée par la base, jamais saisie à la main)
--
--    Aux prix des offres — mensuel 200 $, annuel 250 $ — cela donne
--    20 $ sur un mensuel et 37,50 $ sur un annuel. Le calcul porte sur
--    le cash réellement collecté : si le setter encaisse autre chose
--    qu'un plein tarif, la commission suit sans qu'on y touche.
-- ------------------------------------------------------------
alter table public.leads drop column if exists commission;
alter table public.leads add column commission numeric(10,2)
  generated always as (
    case status
      when 'monthly' then round(cash_collecte * 0.10, 2)
      when 'yearly'  then round(cash_collecte * 0.15, 2)
      else 0
    end
  ) stored;

-- ------------------------------------------------------------
-- 5. INDEX
-- ------------------------------------------------------------
create index if not exists leads_setter_idx    on public.leads (setter_id);
create index if not exists leads_follow_up_idx on public.leads (follow_up_at);

-- ------------------------------------------------------------
-- 6. RÈGLES D'ACCÈS
-- ------------------------------------------------------------
-- Le public (formulaire de la page de vente) : insertion seule.
create policy "public peut deposer un lead"
  on public.leads for insert
  to anon
  with check (
    status = 'nouveau'
    and setter_id is null
    and called_at is null
    and notes is null
    and dials = 0
    and cash_collecte = 0
  );

-- L'équipe : lecture et modification de tous les leads.
drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select
  to authenticated
  using (public.is_staff());

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update
  to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- Suppression réservée aux admins.
drop policy if exists "admin supprime" on public.leads;
create policy "admin supprime"
  on public.leads for delete
  to authenticated
  using (public.is_admin());

-- ------------------------------------------------------------
-- 7. STATISTIQUES — un seul appel pour tout le dashboard
-- ------------------------------------------------------------
create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null
)
returns json
language sql
stable
security invoker
set search_path = public
as $$
  with base as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
  ),
  calc as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters,
      count(*) filter (where status = 'monthly')                   as monthly,
      count(*) filter (where status = 'yearly')                    as yearly,
      count(*) filter (where status in ('monthly','yearly'))       as closed,
      coalesce(sum(cash_collecte), 0)                              as cash,
      coalesce(sum(commission), 0)                                 as commissions,
      count(*) filter (where status = 'follow_up'
                         and follow_up_at is not null
                         and follow_up_at < now())                 as retards
    from base
  )
  select json_build_object(
    'leads',            leads,
    'dials',            dials,
    'joints',           joints,
    'sans_reponse',     sans_reponse,
    'time_wasters',     time_wasters,
    'monthly',          monthly,
    'yearly',           yearly,
    'closed',           closed,
    'cash',             cash,
    'commissions',      commissions,
    'retards',          retards,
    'connection_rate',  case when dials  > 0 then round(joints::numeric  / dials  * 100) else 0 end,
    'tw_rate',          case when joints > 0 then round(time_wasters::numeric / joints * 100) else 0 end,
    'closing_rate',     case when joints > 0 then round(closed::numeric  / joints * 100) else 0 end,
    'yearly_rate',      case when closed > 0 then round(yearly::numeric  / closed * 100) else 0 end
  )
  from calc;
$$;

-- Postgres accorde EXECUTE à PUBLIC par défaut : il faut le retirer
-- explicitement, sinon la clé publique peut appeler la fonction.
revoke all on function public.crm_stats(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. NOTE DE SÉCURITÉ — pas de vue sur `leads`
--
--    Une vue Postgres s'exécute avec les droits de son
--    créateur : elle contourne donc les policies RLS de la
--    table et exposerait les leads à la clé publique.
--    Le CRM interroge la table directement, filtrée par RLS.
--    Si une vue devient nécessaire un jour, la créer avec
--    `with (security_invoker = on)`.
-- ------------------------------------------------------------


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 03-activite.sql
-- ╚══════════════════════════════════════════════════════════
-- ============================================================
--  CRM Ecom Boss — journal d'activité
--  À exécuter dans Supabase → SQL Editor → New query → Run
--
--  Chaque événement de la vie d'un lead est enregistré
--  automatiquement : réception, prise en main, appels, statuts,
--  relances, cash. Le CRM l'affiche en fil chronologique.
-- ============================================================

create table if not exists public.lead_events (
  id         bigserial primary key,
  lead_id    uuid not null references public.leads(id) on delete cascade,
  created_at timestamptz not null default now(),
  auteur     uuid references auth.users on delete set null,
  type       text not null check (type in
               ('creation','assignation','statut','appel','cash','note','relance')),
  detail     jsonb not null default '{}'::jsonb
);

create index if not exists lead_events_lead_idx
  on public.lead_events (lead_id, created_at desc);

alter table public.lead_events enable row level security;

drop policy if exists "staff lit l'activite" on public.lead_events;
create policy "staff lit l'activite"
  on public.lead_events for select
  to authenticated
  using (public.is_staff());

-- ------------------------------------------------------------
--  Le trigger écrit le journal. En security definer, il passe
--  outre RLS : c'est voulu, personne n'écrit ce journal à la main.
-- ------------------------------------------------------------
create or replace function public.journal_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  qui uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, null, 'creation',
            jsonb_build_object('source', coalesce(new.page_url, 'formulaire')));
    return new;
  end if;

  -- prise en main ou réassignation
  if new.setter_id is distinct from old.setter_id and new.setter_id is not null then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'assignation', jsonb_build_object('setter', new.setter_id));
  end if;

  -- changement de statut
  if new.status is distinct from old.status then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'statut',
            jsonb_build_object('avant', old.status::text, 'apres', new.status::text));
  end if;

  -- appels passés
  if new.dials > old.dials then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'appel', jsonb_build_object('numero', new.dials));
  end if;

  -- date de relance posée ou déplacée
  if new.follow_up_at is distinct from old.follow_up_at and new.follow_up_at is not null then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'relance', jsonb_build_object('quand', new.follow_up_at));
  end if;

  -- encaissement
  if new.cash_collecte is distinct from old.cash_collecte and new.cash_collecte > 0 then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'cash',
            jsonb_build_object('montant', new.cash_collecte, 'commission', new.commission));
  end if;

  -- note ajoutée ou modifiée
  if new.notes is distinct from old.notes and new.notes is not null then
    insert into public.lead_events (lead_id, auteur, type, detail)
    values (new.id, qui, 'note', jsonb_build_object('texte', left(new.notes, 280)));
  end if;

  return new;
end;
$$;

drop trigger if exists trg_journal_lead_insert on public.leads;
create trigger trg_journal_lead_insert
  after insert on public.leads
  for each row execute function public.journal_lead();

drop trigger if exists trg_journal_lead_update on public.leads;
create trigger trg_journal_lead_update
  after update on public.leads
  for each row execute function public.journal_lead();

-- ------------------------------------------------------------
--  Vérification : doit renvoyer la table et ses deux triggers
-- ------------------------------------------------------------
select tgname from pg_trigger
where tgrelid = 'public.leads'::regclass and not tgisinternal
order by tgname;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 04-tarifs.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le tarif découle de l'offre, jamais d'une saisie
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Mensuel 200 $, annuel 250 $, et rien pour les autres statuts. Les
--  setters ne négocient pas le prix : le laisser saisissable, c'était
--  ouvrir la porte à une faute de frappe qui devient une commission
--  fausse. La base impose donc le montant elle-même, quelle que soit la
--  valeur envoyée par le client.
-- =====================================================================

create or replace function public.forcer_tarif()
returns trigger
language plpgsql
as $$
begin
  new.cash_collecte := case new.status
    when 'monthly' then 200
    when 'yearly'  then 250
    else 0
  end;
  return new;
end;
$$;

drop trigger if exists trg_forcer_tarif on public.leads;
create trigger trg_forcer_tarif
  before insert or update of status, cash_collecte on public.leads
  for each row execute function public.forcer_tarif();

-- Remet les leads déjà enregistrés au tarif de leur offre. L'écriture
-- déclenche le trigger, qui recalcule à partir du statut.
update public.leads set cash_collecte = 0;

-- La commission suit, puisqu'elle est calculée sur cash_collecte :
--   mensuel  200 × 10 % = 20,00 $
--   annuel   250 × 15 % = 37,50 $


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 05-stats.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Statistiques justes, et cloisonnées par setter
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Trois corrections :
--
--  1. Le taux de connexion divisait des leads par des appels. Un setter
--     qui rappelle trois fois pour joindre quelqu'un voyait son taux
--     s'effondrer alors qu'il avait bien fait son travail.
--
--  2. L'argent suivait la date d'arrivée du lead. Une vente conclue le
--     2 septembre sur un lead reçu le 28 août tombait dans les chiffres
--     d'août. Pour payer des commissions, c'est la date de vente qui
--     compte : on l'enregistre désormais.
--
--  3. N'importe quel membre de l'équipe pouvait demander les chiffres
--     d'un collègue en passant son identifiant à la fonction. Masquer
--     le menu dans l'interface ne suffisait pas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. La date de vente
-- ---------------------------------------------------------------------

alter table public.leads add column if not exists closed_at timestamptz;

comment on column public.leads.closed_at is
  'Quand le lead est passé en vente. Sert à rattacher cash et commission au bon mois.';

create or replace function public.marquer_vente()
returns trigger
language plpgsql
as $$
begin
  if new.status in ('monthly', 'yearly') then
    -- Première vente : on horodate. Un passage de mensuel à annuel ne
    -- redate pas la vente, elle a bien eu lieu au premier closing.
    if new.closed_at is null then new.closed_at := now(); end if;
  else
    -- Le lead sort des statuts de vente : la vente n'a pas eu lieu.
    new.closed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_marquer_vente on public.leads;
create trigger trg_marquer_vente
  before insert or update of status on public.leads
  for each row execute function public.marquer_vente();

-- Rattrape les ventes déjà enregistrées : à défaut de mieux, la date du
-- dernier appel, sinon celle de l'arrivée du lead.
update public.leads
   set closed_at = coalesce(called_at, created_at)
 where status in ('monthly', 'yearly') and closed_at is null;

create index if not exists leads_closed_idx on public.leads (closed_at);

-- ---------------------------------------------------------------------
-- 2. Les chiffres
-- ---------------------------------------------------------------------

create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null
)
returns json
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  resultat json;
begin
  -- Un setter consulte ses propres chiffres, ou ceux de toute l'équipe.
  -- Jamais ceux d'un collègue en particulier.
  if not public.is_admin()
     and p_setter is not null
     and p_setter <> auth.uid() then
    raise exception 'Chiffres réservés : tu peux consulter les tiens ou ceux de toute l''équipe.';
  end if;

  with
  -- Les leads reçus pendant la période : tout ce qui décrit l'activité.
  recus as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
  ),
  -- Les ventes conclues pendant la période : tout ce qui touche l'argent.
  -- Un lead reçu en août et vendu en septembre compte en septembre.
  ventes as (
    select *
    from public.leads
    where status in ('monthly', 'yearly')
      and closed_at is not null
      and (p_debut  is null or closed_at >= p_debut)
      and (p_fin    is null or closed_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
  ),
  -- Les relances en retard décrivent maintenant, pas la période.
  retard as (
    select count(*) as n
    from public.leads
    where status = 'follow_up'
      and follow_up_at is not null
      and follow_up_at < now()
      and (p_setter is null or setter_id = p_setter)
  ),
  activite as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      -- Un lead qu'on n'a jamais appelé ne peut pas compter contre le
      -- taux de connexion : le dénominateur, ce sont les leads tentés.
      count(*) filter (where dials > 0)                            as tentes,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*)                                     as closed,
      coalesce(sum(cash_collecte), 0)              as cash,
      coalesce(sum(commission), 0)                 as commissions
    from ventes
  )
  select json_build_object(
    'leads',            a.leads,
    'dials',            a.dials,
    'tentes',           a.tentes,
    'joints',           a.joints,
    'sans_reponse',     a.sans_reponse,
    'time_wasters',     a.time_wasters,
    'monthly',          v.monthly,
    'yearly',           v.yearly,
    'closed',           v.closed,
    'cash',             v.cash,
    'commissions',      v.commissions,
    'retards',          r.n,

    -- Part des leads appelés qu'on a réussi à joindre.
    'connection_rate',  case when a.tentes > 0
                          then round(a.joints::numeric / a.tentes * 100) else 0 end,
    -- Ventes conclues sur la période, rapportées aux leads joints sur la
    -- même période. C'est le rapprochement que fait un setter de tête, et
    -- les deux nombres sont affichés côte à côte sur le tableau de bord.
    'closing_rate',     case when a.joints > 0
                          then round(v.closed::numeric / a.joints * 100) else 0 end,
    -- Part des leads joints qui font perdre du temps.
    'tw_rate',          case when a.joints > 0
                          then round(a.time_wasters::numeric / a.joints * 100) else 0 end,
    -- Part des ventes qui partent à l'année.
    'yearly_rate',      case when v.closed > 0
                          then round(v.yearly::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid) to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 06-factures.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les factures de paiement, une par vente
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Dès qu'un setter fait rentrer quelqu'un en mensuel ou en annuel, il
--  dépose la facture de paiement du lead. Chacun ne voit que les siennes ;
--  les administrateurs voient tout, ce sont eux qui paient les commissions.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Le seau
-- ---------------------------------------------------------------------
-- Privé : une facture ne s'attrape pas par son adresse. La lecture passe
-- par un lien signé, émis à qui a le droit de le demander.

insert into storage.buckets (id, name, public, file_size_limit)
values ('factures', 'factures', false, 20971520)   -- 20 Mo par fichier
on conflict (id) do update set public = false, file_size_limit = 20971520;

-- Le premier dossier du chemin est l'identifiant du setter : c'est ce qui
-- cloisonne les factures les unes des autres.
-- Les noms de la première version (une facture par mois), à retirer.
drop policy if exists "setter depose sa facture" on storage.objects;
drop policy if exists "setter lit ses factures" on storage.objects;
drop policy if exists "setter retire sa facture" on storage.objects;

drop policy if exists "facture deposee" on storage.objects;
create policy "facture deposee" on storage.objects
  for insert with check (
    bucket_id = 'factures'
    and public.is_staff()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "facture lue" on storage.objects;
create policy "facture lue" on storage.objects
  for select using (
    bucket_id = 'factures'
    and (public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text)
  );

drop policy if exists "facture retiree" on storage.objects;
create policy "facture retiree" on storage.objects
  for delete using (
    bucket_id = 'factures'
    and (public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text)
  );

-- ---------------------------------------------------------------------
-- 2. La table
-- ---------------------------------------------------------------------
-- Une vente, une facture : la contrainte d'unicité sur `lead_id` évite
-- qu'un même paiement soit justifié deux fois.

-- Une première version de ce fichier rangeait les factures par mois, sans
-- `lead_id`. « create table if not exists » laisserait cette table-là en
-- place, et les règles plus bas échoueraient sur une colonne absente. On la
-- retire — mais jamais si elle contient quelque chose.
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'invoices'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'invoices' and column_name = 'lead_id'
  ) then
    if exists (select 1 from public.invoices limit 1) then
      raise exception 'La table invoices contient des factures au format mensuel : sauvegarde-les avant de rejouer ce fichier.';
    end if;
    drop table public.invoices;
  end if;
end $$;

create table if not exists public.invoices (
  id         bigint generated always as identity primary key,
  lead_id    uuid   not null unique references public.leads on delete cascade,
  setter_id  uuid   not null references auth.users on delete cascade default auth.uid(),
  file_path  text not null,
  file_name  text,
  taille     int,
  created_at timestamptz not null default now()
);

create index if not exists invoices_setter_idx on public.invoices (setter_id);

alter table public.invoices enable row level security;

drop policy if exists "facture lue" on public.invoices;
create policy "facture lue" on public.invoices
  for select to authenticated
  using (setter_id = auth.uid() or public.is_admin());

-- On ne dépose une facture que pour un lead qu'on a soi-même conclu.
drop policy if exists "facture deposee" on public.invoices;
create policy "facture deposee" on public.invoices
  for insert to authenticated
  with check (
    setter_id = auth.uid()
    and public.is_staff()
    and exists (
      select 1 from public.leads l
      where l.id = invoices.lead_id
        and l.setter_id = auth.uid()
        and l.status in ('monthly', 'yearly')
    )
  );

-- Redéposer remplace la facture : la mise à jour est le second temps de
-- l'upsert, sans quoi le remplacement bute sur la contrainte d'unicité.
drop policy if exists "facture remplacee" on public.invoices;
create policy "facture remplacee" on public.invoices
  for update to authenticated
  using (setter_id = auth.uid())
  with check (setter_id = auth.uid() and public.is_staff());

drop policy if exists "facture retiree" on public.invoices;
create policy "facture retiree" on public.invoices
  for delete to authenticated
  using (setter_id = auth.uid() or public.is_admin());


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 07-iclosed.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Relance iClosed : un second vivier de leads
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Des gens qui ont pris un call il y a un, deux ou trois mois et qu'on
--  rappelle. Une centaine par semaine, importés par un administrateur et
--  attribués à la main.
--
--  Ce sont des leads comme les autres : même table, même fiche, mêmes
--  statuts, même tarif, même commission — et donc la même facture à
--  déposer dès qu'un passage en Monthly ou Yearly est enregistré. Seule
--  une marque les distingue, pour que les deux viviers ne se mélangent
--  ni dans les listes ni dans les chiffres.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. La première version, abandonnée
-- ---------------------------------------------------------------------
-- Un carnet séparé, tenu à la main par chaque setter. Ce n'était pas ça :
-- ce sont de vrais leads, ils vivent avec les autres.

do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'iclosed_relances'
  ) then
    if exists (select 1 from public.iclosed_relances limit 1) then
      raise exception 'La table iclosed_relances contient des fiches : sauvegarde-les avant de rejouer ce fichier.';
    end if;
    drop table public.iclosed_relances;
    drop function if exists public.toucher_iclosed();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. D'où vient le lead
-- ---------------------------------------------------------------------

alter table public.leads
  add column if not exists source text not null default 'formulaire';

alter table public.leads drop constraint if exists leads_source_check;
alter table public.leads add constraint leads_source_check
  check (source in ('formulaire', 'iclosed'));

comment on column public.leads.source is
  'formulaire = page de vente ; iclosed = call pris il y a plusieurs mois, à rappeler.';

create index if not exists leads_source_idx on public.leads (source, created_at desc);

-- `created_at` porte la date du call d'origine pour un lead iClosed : c'est
-- le repère utile au téléphone — « tu as pris un call avec nous en juin ».

-- ---------------------------------------------------------------------
-- 2. Un administrateur peut ajouter des leads
-- ---------------------------------------------------------------------
-- Jusqu'ici seul le formulaire public en déposait. L'import iClosed passe
-- par le CRM, donc par un compte connecté — et par un administrateur seul,
-- puisque c'est lui qui répartit.

drop policy if exists "admin ajoute des leads" on public.leads;
create policy "admin ajoute des leads"
  on public.leads for insert
  to authenticated
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 3. Les chiffres, vivier par vivier
-- ---------------------------------------------------------------------
-- Cent vieux leads mélangés aux leads frais écraseraient le connection
-- rate et le closing rate, qui ne voudraient plus rien dire. La fonction
-- accepte donc de ne regarder qu'un vivier.

drop function if exists public.crm_stats(timestamptz, timestamptz, uuid);

create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null,
  p_source text        default null
)
returns json
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  resultat json;
begin
  -- Un setter consulte ses propres chiffres, ou ceux de toute l'équipe.
  -- Jamais ceux d'un collègue en particulier.
  if not public.is_admin()
     and p_setter is not null
     and p_setter <> auth.uid() then
    raise exception 'Chiffres réservés : tu peux consulter les tiens ou ceux de toute l''équipe.';
  end if;

  with
  recus as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_source is null or source = p_source)
  ),
  ventes as (
    select *
    from public.leads
    where status in ('monthly', 'yearly')
      and closed_at is not null
      and (p_debut  is null or closed_at >= p_debut)
      and (p_fin    is null or closed_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_source is null or source = p_source)
  ),
  retard as (
    select count(*) as n
    from public.leads
    where status = 'follow_up'
      and follow_up_at is not null
      and follow_up_at < now()
      and (p_setter is null or setter_id = p_setter)
      and (p_source is null or source = p_source)
  ),
  activite as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      count(*) filter (where dials > 0)                            as tentes,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*)                                     as closed,
      coalesce(sum(cash_collecte), 0)              as cash,
      coalesce(sum(commission), 0)                 as commissions
    from ventes
  )
  select json_build_object(
    'leads',            a.leads,
    'dials',            a.dials,
    'tentes',           a.tentes,
    'joints',           a.joints,
    'sans_reponse',     a.sans_reponse,
    'time_wasters',     a.time_wasters,
    'monthly',          v.monthly,
    'yearly',           v.yearly,
    'closed',           v.closed,
    'cash',             v.cash,
    'commissions',      v.commissions,
    'retards',          r.n,
    'connection_rate',  case when a.tentes > 0
                          then round(a.joints::numeric / a.tentes * 100) else 0 end,
    'closing_rate',     case when a.joints > 0
                          then round(v.closed::numeric / a.joints * 100) else 0 end,
    'tw_rate',          case when a.joints > 0
                          then round(a.time_wasters::numeric / a.joints * 100) else 0 end,
    'yearly_rate',      case when v.closed > 0
                          then round(v.yearly::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid, text) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid, text) to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 08-vivier.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Réparer le formulaire : « source » ne m'appartenait pas
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  `leads.source` existait avant le CRM : la page de vente y met le
--  référent du visiteur, d'où il arrive. 07-iclosed.sql lui a imposé
--  une contrainte « formulaire ou iclosed » — et à partir de là, toute
--  soumission portant un vrai référent était refusée par la base.
--
--  Les leads perdus entre-temps ne sont pas récupérables : ils n'ont
--  jamais été écrits. Ce fichier rend `source` à son rôle d'origine et
--  déplace la marque du vivier dans sa propre colonne.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. La marque du vivier prend sa propre colonne
-- ---------------------------------------------------------------------

alter table public.leads
  add column if not exists vivier text not null default 'formulaire';

alter table public.leads drop constraint if exists leads_vivier_check;
alter table public.leads add constraint leads_vivier_check
  check (vivier in ('formulaire', 'iclosed'));

comment on column public.leads.vivier is
  'formulaire = page de vente ; iclosed = call pris il y a plusieurs mois, à rappeler.';

-- Les leads déjà importés gardent leur vivier.
update public.leads set vivier = 'iclosed' where source = 'iclosed';

-- ---------------------------------------------------------------------
-- 2. « source » redevient le référent
-- ---------------------------------------------------------------------
-- On efface les deux seules valeurs que le CRM y avait écrites. Un vrai
-- référent est une adresse : aucun risque de confusion.

alter table public.leads drop constraint if exists leads_source_check;
update public.leads set source = null where source in ('formulaire', 'iclosed');

comment on column public.leads.source is
  'Référent du visiteur, tel que le navigateur l''annonce. Écrit par la page de vente.';

drop index if exists public.leads_source_idx;
create index if not exists leads_vivier_idx on public.leads (vivier, created_at desc);

-- ---------------------------------------------------------------------
-- 3. Les chiffres suivent le vivier, pas le référent
-- ---------------------------------------------------------------------

drop function if exists public.crm_stats(timestamptz, timestamptz, uuid, text);

create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null,
  p_vivier text        default null
)
returns json
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  resultat json;
begin
  if not public.is_admin()
     and p_setter is not null
     and p_setter <> auth.uid() then
    raise exception 'Chiffres réservés : tu peux consulter les tiens ou ceux de toute l''équipe.';
  end if;

  with
  recus as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
  ),
  ventes as (
    select *
    from public.leads
    where status in ('monthly', 'yearly')
      and closed_at is not null
      and (p_debut  is null or closed_at >= p_debut)
      and (p_fin    is null or closed_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
  ),
  retard as (
    select count(*) as n
    from public.leads
    where status = 'follow_up'
      and follow_up_at is not null
      and follow_up_at < now()
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
  ),
  activite as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      count(*) filter (where dials > 0)                            as tentes,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*)                                     as closed,
      coalesce(sum(cash_collecte), 0)              as cash,
      coalesce(sum(commission), 0)                 as commissions
    from ventes
  )
  select json_build_object(
    'leads',            a.leads,
    'dials',            a.dials,
    'tentes',           a.tentes,
    'joints',           a.joints,
    'sans_reponse',     a.sans_reponse,
    'time_wasters',     a.time_wasters,
    'monthly',          v.monthly,
    'yearly',           v.yearly,
    'closed',           v.closed,
    'cash',             v.cash,
    'commissions',      v.commissions,
    'retards',          r.n,
    'connection_rate',  case when a.tentes > 0
                          then round(a.joints::numeric / a.tentes * 100) else 0 end,
    'closing_rate',     case when a.joints > 0
                          then round(v.closed::numeric / a.joints * 100) else 0 end,
    'tw_rate',          case when a.joints > 0
                          then round(a.time_wasters::numeric / a.joints * 100) else 0 end,
    'yearly_rate',      case when v.closed > 0
                          then round(v.yearly::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid, text) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid, text) to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 09-temps-reel.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le CRM en direct
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Les setters passent leur matinée sur « Leads du jour » à attendre.
--  Sans ça, un lead qui arrive ne se voit qu'après un rechargement, et
--  un lead pris par un collègue reste affiché comme libre.
--
--  Publier la table permet à Supabase d'annoncer ses changements aux
--  navigateurs connectés. Les règles RLS continuent de s'appliquer :
--  personne ne reçoit ce qu'il n'a pas le droit de lire.
-- =====================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'leads'
  ) then
    alter publication supabase_realtime add table public.leads;
  end if;
end $$;

-- Une mise à jour n'annonce par défaut que les colonnes de la clé. Pour
-- savoir qu'un lead vient d'être pris, il faut la ligne entière.
alter table public.leads replica identity full;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 10-appels.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Un lead pris est un lead appelé
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Personne n'incrémente le compteur d'appels à la main. Résultat, aucun
--  lead n'était « tenté », et le connection rate affichait zéro en
--  permanence : la moitié du dashboard ne servait à rien.
--
--  Or prendre un lead dans le vivier, c'est décrocher son téléphone dans
--  la minute — le délai de dix minutes ne laisse pas le choix. On compte
--  donc le premier appel à ce moment-là.
-- =====================================================================

create or replace function public.compter_le_premier_appel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.dials > 0 then return new; end if;

  -- 1. Un setter prend un lead du vivier : il va l'appeler.
  --
  --    La condition sur auth.uid() est ce qui distingue le geste du
  --    setter de l'attribution en masse : un administrateur qui répartit
  --    cent leads iClosed n'a passé aucun appel, et son import ne doit
  --    pas en inventer cent.
  if new.setter_id is not null
     and old.setter_id is null
     and new.setter_id = auth.uid() then
    new.dials := 1;
    return new;
  end if;

  -- 2. Un lead iClosed, attribué par un administrateur, sort de
  --    « nouveau » : c'est qu'on vient de lui parler, ou d'essayer.
  if old.status = 'nouveau' and new.status <> 'nouveau' then
    new.dials := 1;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_compter_le_premier_appel on public.leads;
create trigger trg_compter_le_premier_appel
  before update on public.leads
  for each row execute function public.compter_le_premier_appel();

comment on column public.leads.dials is
  'Nombre d''appels passés. Le premier se compte tout seul — à la prise du lead, ou au premier changement de statut. Les suivants se saisissent dans la fiche.';


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 11-enregistrements.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les enregistrements d'appel
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Le setter lance l'enregistrement avant de composer, met son téléphone
--  en haut-parleur, et arrête à la fin. Le navigateur capte le micro de
--  l'ordinateur — il n'a aucun accès à la ligne téléphonique, c'est la
--  seule prise possible depuis une page web.
--
--  Le fichier est privé et rattaché au lead. Chacun n'entend que ses
--  propres appels ; les administrateurs les entendent tous.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Le seau
-- ---------------------------------------------------------------------
-- Un enregistrement de conversation ne s'attrape pas par son adresse :
-- la lecture passe par un lien signé, valable le temps de l'écoute.

insert into storage.buckets (id, name, public, file_size_limit)
values ('appels', 'appels', false, 104857600)   -- 100 Mo, soit des heures de parole
on conflict (id) do update set public = false, file_size_limit = 104857600;

drop policy if exists "appel depose" on storage.objects;
create policy "appel depose" on storage.objects
  for insert with check (
    bucket_id = 'appels'
    and public.is_staff()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "appel ecoute" on storage.objects;
create policy "appel ecoute" on storage.objects
  for select using (
    bucket_id = 'appels'
    and (public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text)
  );

drop policy if exists "appel efface" on storage.objects;
create policy "appel efface" on storage.objects
  for delete using (
    bucket_id = 'appels'
    and (public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text)
  );

-- ---------------------------------------------------------------------
-- 2. La table
-- ---------------------------------------------------------------------

create table if not exists public.lead_calls (
  id         bigint generated always as identity primary key,
  lead_id    uuid not null references public.leads on delete cascade,
  setter_id  uuid not null references auth.users on delete cascade default auth.uid(),
  file_path  text not null,
  duree_s    int,
  taille     int,
  created_at timestamptz not null default now()
);

create index if not exists lead_calls_lead_idx on public.lead_calls (lead_id, created_at desc);

alter table public.lead_calls enable row level security;

drop policy if exists "appel lu" on public.lead_calls;
create policy "appel lu" on public.lead_calls
  for select to authenticated
  using (setter_id = auth.uid() or public.is_admin());

drop policy if exists "appel enregistre" on public.lead_calls;
create policy "appel enregistre" on public.lead_calls
  for insert to authenticated
  with check (setter_id = auth.uid() and public.is_staff());

drop policy if exists "appel supprime" on public.lead_calls;
create policy "appel supprime" on public.lead_calls
  for delete to authenticated
  using (setter_id = auth.uid() or public.is_admin());


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 12-lead-sans-nom.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Un lead importé n'a pas toujours de nom, ni d'e-mail
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  La table `leads` a été créée par le formulaire de la page de vente,
--  qui demande tout : prénom, nom, e-mail, téléphone. D'où des colonnes
--  toutes obligatoires. Les listes iClosed, elles, arrivent trouées —
--  et refuser un numéro parfaitement appelable pour une case vide ferait
--  perdre le lead.
--
--  Le téléphone reste obligatoire : c'est la seule chose dont on ait
--  vraiment besoin dans un vivier de rappels.
-- =====================================================================

alter table public.leads alter column first_name drop not null;
alter table public.leads alter column last_name  drop not null;
alter table public.leads alter column email      drop not null;

comment on column public.leads.first_name is
  'Facultatif : une liste importée n''a pas toujours le nom. Le CRM affiche alors le numéro.';
comment on column public.leads.last_name is
  'Facultatif, comme le prénom.';
comment on column public.leads.email is
  'Facultatif sur un lead importé ; toujours renseigné par le formulaire.';

-- Le formulaire public, lui, continue d'exiger ses quatre champs côté
-- page de vente : rien ne change pour lui.

-- Ce qui reste obligatoire, pour vérification :
select column_name, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'leads'
  and column_name in ('first_name', 'last_name', 'email', 'phone')
order by column_name;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 13-message-envoye.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  « Message envoyé » sur les relances iClosed
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Une relance commence souvent par un message, pas par un appel. Sans
--  trace, un setter qui reprend sa liste le lendemain ne sait plus qui
--  il a contacté — et recontacte les mêmes en laissant les autres.
--
--  L'horodatage plutôt qu'une simple case : savoir « quand » vaut mieux
--  que savoir « oui », et il ne coûte rien de plus.
-- =====================================================================

alter table public.leads add column if not exists message_at timestamptz;

comment on column public.leads.message_at is
  'Quand un message a été envoyé au lead. Null = pas encore contacté par écrit.';

create index if not exists leads_message_idx on public.leads (message_at)
  where message_at is not null;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 14-equipes.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Deux équipes dans le même CRM
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Les setters Base44 travaillent les leads du formulaire et les calls
--  iClosed. Les setters de l'équipe Skool n'ont ni l'un ni l'autre :
--  ils saisissent leurs leads à la main.
--
--  Les deux ne doivent jamais se croiser. La séparation vit ici, dans les
--  policies : masquer un onglet ne protège rien, quelqu'un qui appelle
--  l'API à la main passerait outre. Les administrateurs, eux, voient les
--  deux et basculent de l'une à l'autre.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. À quelle équipe on appartient
-- ---------------------------------------------------------------------

alter table public.staff add column if not exists equipe text not null default 'starter';
alter table public.leads add column if not exists equipe text not null default 'starter';

alter table public.staff drop constraint if exists staff_equipe_check;
alter table public.staff add constraint staff_equipe_check
  check (equipe in ('starter', 'skool'));

alter table public.leads drop constraint if exists leads_equipe_check;
alter table public.leads add constraint leads_equipe_check
  check (equipe in ('starter', 'skool'));

comment on column public.staff.equipe is
  'starter = l''équipe Base44 (leads du formulaire) ; skool = l''équipe Skool (appels réservés sur le calendrier de chaque setter).';
comment on column public.leads.equipe is
  'L''équipe à qui ce lead appartient. Un setter ne voit jamais ceux de l''autre.';

create index if not exists leads_equipe_idx on public.leads (equipe, created_at desc);

-- security definer : la fonction lit `staff` sans repasser par RLS, ce qui
-- éviterait une récursion dans les policies qui l'appellent.
create or replace function public.mon_equipe()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select equipe from public.staff where user_id = auth.uid() and actif;
$$;

-- ---------------------------------------------------------------------
-- 2. Chacun chez soi
-- ---------------------------------------------------------------------

drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select
  to authenticated
  using (public.is_admin() or (public.is_staff() and equipe = public.mon_equipe()));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update
  to authenticated
  using  (public.is_admin() or (public.is_staff() and equipe = public.mon_equipe()))
  with check (public.is_admin() or (public.is_staff() and equipe = public.mon_equipe()));

-- Saisir un lead à la main : c'est le seul moyen d'en avoir pour
-- l'accompagnement. On l'ouvre à toute l'équipe, mais dans son propre
-- vivier et à son propre nom — impossible d'en déposer chez le voisin.
drop policy if exists "staff saisit un lead" on public.leads;
create policy "staff saisit un lead"
  on public.leads for insert
  to authenticated
  with check (
    public.is_admin()
    or (public.is_staff() and equipe = public.mon_equipe() and setter_id = auth.uid())
  );

-- L'annuaire suit la même règle : un setter n'a pas à connaître les noms
-- de l'autre équipe.
drop policy if exists "staff se voit" on public.staff;
create policy "staff se voit"
  on public.staff for select
  to authenticated
  using (public.is_admin() or (public.is_staff() and equipe = public.mon_equipe()));

-- ---------------------------------------------------------------------
-- 3. Les chiffres, équipe par équipe
-- ---------------------------------------------------------------------
-- La fonction s'exécute avec les droits de l'appelant, donc un setter est
-- déjà borné à son équipe par les policies ci-dessus. Le paramètre ne sert
-- qu'aux administrateurs, qui voient les deux et choisissent laquelle.

drop function if exists public.crm_stats(timestamptz, timestamptz, uuid, text);

create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null,
  p_vivier text        default null,
  p_equipe text        default null
)
returns json
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  resultat json;
begin
  if not public.is_admin()
     and p_setter is not null
     and p_setter <> auth.uid() then
    raise exception 'Chiffres réservés : tu peux consulter les tiens ou ceux de toute l''équipe.';
  end if;

  with
  recus as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  ventes as (
    select *
    from public.leads
    where status in ('monthly', 'yearly')
      and closed_at is not null
      and (p_debut  is null or closed_at >= p_debut)
      and (p_fin    is null or closed_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  retard as (
    select count(*) as n
    from public.leads
    where status = 'follow_up'
      and follow_up_at is not null
      and follow_up_at < now()
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  activite as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      count(*) filter (where dials > 0)                            as tentes,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*)                                     as closed,
      coalesce(sum(cash_collecte), 0)              as cash,
      coalesce(sum(commission), 0)                 as commissions
    from ventes
  )
  select json_build_object(
    'leads',            a.leads,
    'dials',            a.dials,
    'tentes',           a.tentes,
    'joints',           a.joints,
    'sans_reponse',     a.sans_reponse,
    'time_wasters',     a.time_wasters,
    'monthly',          v.monthly,
    'yearly',           v.yearly,
    'closed',           v.closed,
    'cash',             v.cash,
    'commissions',      v.commissions,
    'retards',          r.n,
    'connection_rate',  case when a.tentes > 0
                          then round(a.joints::numeric / a.tentes * 100) else 0 end,
    'closing_rate',     case when a.joints > 0
                          then round(v.closed::numeric / a.joints * 100) else 0 end,
    'tw_rate',          case when a.joints > 0
                          then round(a.time_wasters::numeric / a.joints * 100) else 0 end,
    'yearly_rate',      case when v.closed > 0
                          then round(v.yearly::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid, text, text) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Ranger l'équipe Skool
-- ---------------------------------------------------------------------
-- Tout le monde est en 'starter' (équipe Base44) par défaut. Le plus simple :
-- mettre "equipe": "skool" dans scripts/equipe.json avant de créer les
-- comptes. Sinon, décommente et complète avec les prénoms :
--
-- update public.staff set equipe = 'skool'
-- where first_name in ('Prénom1', 'Prénom2', 'Prénom3');

-- Qui est où, pour vérifier :
select equipe, role, first_name, last_name, actif
from public.staff
order by equipe, role desc, first_name;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 15-vagues.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les vagues de relance iClosed
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Un setter reçoit une liste, la travaille, puis en reçoit une autre.
--  Sans repère, les deux se mélangent dans son pipeline : il ne sait plus
--  qui il a déjà appelé et qui il n'a jamais contacté.
--
--  Chaque import porte donc son numéro de vague, et le setter passe de
--  l'une à l'autre d'un clic.
-- =====================================================================

alter table public.leads add column if not exists vague int;

comment on column public.leads.vague is
  'Le lot d''import dont vient ce lead iClosed. 1 = la première liste, 2 = la suivante.';

-- Tout ce qui existe déjà est la première vague.
update public.leads set vague = 1
where vivier = 'iclosed' and vague is null;

create index if not exists leads_vague_idx on public.leads (vivier, vague)
  where vivier = 'iclosed';

-- ---------------------------------------------------------------------
-- Les vagues disponibles, et ce qu'il reste à faire dans chacune
-- ---------------------------------------------------------------------
-- security invoker : les policies s'appliquent, donc un setter ne compte
-- que ce qu'il a le droit de voir. Le paramètre `p_setter` sert au setter
-- pour se limiter à lui-même, et à l'administrateur pour désigner
-- quelqu'un.

create or replace function public.vagues_iclosed(
  p_setter uuid default null,
  p_equipe text default null
)
returns table (vague int, total bigint, a_faire bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(l.vague, 1) as vague,
         count(*)                                   as total,
         count(*) filter (where l.status = 'nouveau') as a_faire
  from public.leads l
  where l.vivier = 'iclosed'
    and (p_setter is null or l.setter_id = p_setter)
    and (p_equipe is null or l.equipe = p_equipe)
  group by 1
  order by 1;
$$;

revoke all on function public.vagues_iclosed(uuid, text) from public, anon;
grant execute on function public.vagues_iclosed(uuid, text) to authenticated;

-- Ce que ça donne aujourd'hui :
select vague, count(*) as leads
from public.leads
where vivier = 'iclosed'
group by vague
order by vague;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 16-formulaire-rempli.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Quand le lead a rempli le formulaire
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Deux faits différents méritaient deux colonnes. `created_at` dit quand
--  le lead est entré dans le CRM ; cette colonne-ci dit quand la personne
--  a laissé ses coordonnées, parfois des mois plus tôt.
--
--  Les confondre faisait afficher « formulaire rempli le 31/08 » sur la
--  première vague, dont on n'a jamais eu la date : le CRM aurait affirmé
--  quelque chose de faux, et le setter l'aurait dit au téléphone.
--
--  Elle reste vide quand le fichier importé ne la donne pas — et le CRM
--  n'affiche alors rien plutôt que d'inventer.
-- =====================================================================

alter table public.leads add column if not exists formulaire_at timestamptz;

comment on column public.leads.formulaire_at is
  'Quand la personne a rempli le formulaire d''origine, si le fichier importé le disait. Null sinon.';

create index if not exists leads_formulaire_idx on public.leads (formulaire_at)
  where formulaire_at is not null;

-- Vérification : la première vague doit rester à zéro.
select coalesce(vague, 1) as vague,
       count(*)                                        as leads,
       count(*) filter (where formulaire_at is not null) as avec_date
from public.leads
where vivier = 'iclosed'
group by 1
order by 1;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 18-equipe-closer.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  (Mexed) Une troisième équipe : retirée pour Sirius, seules restent Base44 et Skool
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  L'équipe Skool fonctionne ainsi : ni vivier du jour ni
--  relances iClosed, des leads saisis à la main, et une étanchéité totale
--  avec les deux autres équipes.
--
--  Rien d'autre à changer : les policies posées en 14-equipes.sql
--  comparent l'équipe du lead à celle de qui regarde, sans connaître la
--  liste des équipes. Seule la contrainte devait s'ouvrir.
-- =====================================================================

alter table public.staff drop constraint if exists staff_equipe_check;
alter table public.staff add constraint staff_equipe_check
  check (equipe in ('starter', 'skool'));

alter table public.leads drop constraint if exists leads_equipe_check;
alter table public.leads add constraint leads_equipe_check
  check (equipe in ('starter', 'skool'));

comment on column public.staff.equipe is
  'starter = l''équipe Base44 (leads du formulaire) ; skool = l''équipe Skool (appels réservés sur le calendrier de chaque setter).';

-- Qui est où :
select equipe, count(*) as personnes
from public.staff
group by equipe
order by equipe;


-- ╔══════════════════════════════════════════════════════════
-- ║  B. CRM — 19-plusieurs-equipes.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Une personne dans plusieurs équipes
--  À passer EN DEUX FOIS — voir « PARTIE 1 » et « PARTIE 2 » plus bas.
--  Chaque partie est rejouable.
--
--  Pourquoi deux fois : le CRM est ouvert chez cinquante personnes qui
--  lisent `staff` et `leads` en continu. Une migration qui verrouille les
--  deux tables dans la même transaction finit par se croiser avec une de
--  ces lectures, et Postgres en tue une — la nôtre. Séparées, chaque
--  partie ne tient qu'un verrou à la fois, brièvement.
--
--  Un setter peut travailler dans plusieurs équipes (par défaut : une seule).
--  `equipe` reste leur équipe principale — celle qui s'ouvre à la
--  connexion — et `equipes` liste toutes celles où ils peuvent aller.
--  Ils basculent de l'une à l'autre avec le même menu que les
--  administrateurs.
--
--  L'étanchéité ne change pas de nature : un lead reste visible pour les
--  équipes qui y ont droit, et pour personne d'autre.
-- =====================================================================

-- =====================================================================
--  PARTIE 1 — colle jusqu'à la ligne « FIN DE LA PARTIE 1 », Run.
-- =====================================================================

-- Si la table est occupée, on abandonne vite et proprement plutôt que
-- d'attendre un croisement de verrous. Il suffit de relancer.
set lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 1. La liste des équipes accessibles
-- ---------------------------------------------------------------------

alter table public.staff add column if not exists equipes text[];

-- Par défaut, sa seule équipe : rien ne change pour ceux qu'on ne touche pas.
update public.staff set equipes = array[equipe] where equipes is null;

alter table public.staff alter column equipes set not null;
alter table public.staff alter column equipes set default '{}';

-- L'équipe principale fait toujours partie de la liste.
create or replace function public.staff_equipes_coherentes()
returns trigger language plpgsql as $$
begin
  if not (new.equipe = any(new.equipes)) then
    new.equipes := array_prepend(new.equipe, new.equipes);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_staff_equipes on public.staff;
create trigger trg_staff_equipes
  before insert or update of equipe, equipes on public.staff
  for each row execute function public.staff_equipes_coherentes();

comment on column public.staff.equipes is
  'Toutes les équipes où la personne peut travailler. `equipe` est celle qui s''ouvre à la connexion.';

create or replace function public.mes_equipes()
returns text[]
language sql stable security definer set search_path = public
as $$
  select coalesce(equipes, array[equipe]) from public.staff
  where user_id = auth.uid() and actif;
$$;

-- ============================ FIN DE LA PARTIE 1 ============================


-- =====================================================================
--  PARTIE 2 — colle d'ici jusqu'à la fin, Run.
-- =====================================================================

set lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 2. Les policies regardent la liste, plus une seule valeur
-- ---------------------------------------------------------------------

drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin() or (public.is_staff() and equipe = any(public.mes_equipes())));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin() or (public.is_staff() and equipe = any(public.mes_equipes())))
  with check (public.is_admin() or (public.is_staff() and equipe = any(public.mes_equipes())));

drop policy if exists "staff saisit un lead" on public.leads;
create policy "staff saisit un lead"
  on public.leads for insert to authenticated
  with check (
    public.is_admin()
    or (public.is_staff() and equipe = any(public.mes_equipes()) and setter_id = auth.uid())
  );

drop policy if exists "staff se voit" on public.staff;
create policy "staff se voit"
  on public.staff for select to authenticated
  using (public.is_admin() or (public.is_staff() and equipe = any(public.mes_equipes())));

-- Qui peut aller où :
select s.first_name, s.equipe as principale, s.equipes
from public.staff s
where array_length(s.equipes, 1) > 1 or s.equipe = 'skool'
order by s.first_name;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — préparation (rejouable)
-- ╚══════════════════════════════════════════════════════════

-- Ces fonctions renvoient une table dont les colonnes changent d'une
-- migration à l'autre. Postgres refuse de « remplacer » une fonction par
-- une autre forme : on les retire avant de rejouer, les migrations les
-- recréent dans leur version finale. Aucune policy ne s'appuie dessus.
drop function if exists public.my_modules();
drop function if exists public.mon_workshop();
drop function if exists public.plan_matrix();
drop function if exists public.etat_portes();


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — schema.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Espace membre Sirius — schéma
--  À coller dans Supabase → SQL Editor → New query → Run.
--
--  Principe : la progression et le déverrouillage sont calculés et
--  appliqués ici, pas dans le navigateur. Un élève qui bidouillerait le
--  JavaScript de la page ne verrait toujours pas les leçons verrouillées :
--  Postgres refuse de les lui renvoyer.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Membres
-- ---------------------------------------------------------------------
-- Un membre est un compte Supabase Auth auquel un setter a ouvert l'accès
-- après l'appel. `lead_id` garde le lien avec la demande d'origine.

create table if not exists public.members (
  id          uuid primary key references auth.users(id) on delete cascade,
  lead_id     uuid,
  email       text not null,
  first_name  text,
  last_name   text,
  role        text not null default 'member' check (role in ('member', 'admin')),
  activated_at timestamptz not null default now()
);

create index if not exists members_lead_idx on public.members(lead_id);

-- ---------------------------------------------------------------------
-- 2. Contenu
-- ---------------------------------------------------------------------
-- `position` porte l'ordre : c'est lui qui décide quel module ouvre le
-- suivant. `video_id` devient `video_path` en 03-videos.sql : le chemin
-- du fichier dans le seau Supabase Storage.

create table if not exists public.modules (
  id          bigint generated always as identity primary key,
  position    int  not null unique,
  title       text not null,
  description text
);

create table if not exists public.lessons (
  id               bigint generated always as identity primary key,
  module_id        bigint not null references public.modules(id) on delete cascade,
  position         int    not null,
  title            text   not null,
  video_id         text,
  duration_seconds int,
  unique (module_id, position)
);

create index if not exists lessons_module_idx on public.lessons(module_id, position);

-- ---------------------------------------------------------------------
-- 3. Progression
-- ---------------------------------------------------------------------

create table if not exists public.lesson_progress (
  member_id    uuid   not null references public.members(id) on delete cascade,
  lesson_id    bigint not null references public.lessons(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (member_id, lesson_id)
);

-- ---------------------------------------------------------------------
-- 4. Règles de déverrouillage
-- ---------------------------------------------------------------------
-- `security definer` : ces fonctions lisent lessons et lesson_progress en
-- passant outre RLS, sinon le calcul du pourcentage ne verrait que les
-- leçons déjà accessibles et le premier module ne s'ouvrirait jamais.

create or replace function public.is_admin(p_user uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from members where id = p_user and role = 'admin');
$$;

create or replace function public.module_completion(p_member uuid, p_module bigint)
returns numeric
language sql stable security definer set search_path = public
as $$
  select case
           when count(l.id) = 0 then 1
           else count(p.lesson_id)::numeric / count(l.id)
         end
  from lessons l
  left join lesson_progress p
         on p.lesson_id = l.id and p.member_id = p_member
  where l.module_id = p_module;
$$;

-- Un module est ouvert si tous ceux qui le précèdent sont terminés.
-- Le premier module n'a aucun prédécesseur : bool_and sur zéro ligne
-- renvoie null, d'où le coalesce à true.
create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(bool_and(module_completion(p_member, m.id) >= 1), true)
  from modules m
  where m.position < (select position from modules where id = p_module);
$$;

-- Ce que le front consomme pour dessiner la liste des modules.
create or replace function public.my_modules()
returns table (
  id          bigint,
  -- « position » est un mot réservé dans une déclaration returns table :
  -- il doit être cité, alors qu'il passe tel quel comme nom de colonne.
  "position"  int,
  title       text,
  description text,
  lesson_count int,
  done_count   int,
  completion   numeric,
  unlocked     boolean
)
language sql stable security definer set search_path = public
as $$
  select m.id,
         m.position,
         m.title,
         m.description,
         (select count(*)::int from lessons l where l.module_id = m.id),
         (select count(*)::int
            from lessons l
            join lesson_progress p
              on p.lesson_id = l.id and p.member_id = auth.uid()
           where l.module_id = m.id),
         module_completion(auth.uid(), m.id),
         is_module_unlocked(auth.uid(), m.id)
  from modules m
  order by m.position;
$$;

-- ---------------------------------------------------------------------
-- 5. Sécurité
-- ---------------------------------------------------------------------

alter table public.members         enable row level security;
alter table public.modules         enable row level security;
alter table public.lessons         enable row level security;
alter table public.lesson_progress enable row level security;

-- Membres : chacun se voit ; un admin voit tout le monde.
drop policy if exists "membre lit sa fiche" on public.members;
create policy "membre lit sa fiche" on public.members
  for select using (id = auth.uid() or is_admin(auth.uid()));

drop policy if exists "admin gère les membres" on public.members;
create policy "admin gère les membres" on public.members
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- Modules : visibles par tout membre connecté (le titre d'un module
-- verrouillé s'affiche, avec son cadenas).
drop policy if exists "membre lit les modules" on public.modules;
create policy "membre lit les modules" on public.modules
  for select using (auth.uid() is not null);

drop policy if exists "admin gère les modules" on public.modules;
create policy "admin gère les modules" on public.modules
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- Leçons : le verrou est ici. Tant que le module précédent n'est pas
-- terminé, la requête ne renvoie rien — y compris l'identifiant vidéo.
drop policy if exists "membre lit les leçons débloquées" on public.lessons;
create policy "membre lit les leçons débloquées" on public.lessons
  for select using (
    is_admin(auth.uid())
    or (auth.uid() is not null and is_module_unlocked(auth.uid(), module_id))
  );

drop policy if exists "admin gère les leçons" on public.lessons;
create policy "admin gère les leçons" on public.lessons
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- Progression : on n'écrit que la sienne, et seulement sur une leçon
-- qu'on a le droit de voir.
drop policy if exists "membre lit sa progression" on public.lesson_progress;
create policy "membre lit sa progression" on public.lesson_progress
  for select using (member_id = auth.uid() or is_admin(auth.uid()));

drop policy if exists "membre marque une leçon vue" on public.lesson_progress;
create policy "membre marque une leçon vue" on public.lesson_progress
  for insert with check (
    member_id = auth.uid()
    and is_module_unlocked(auth.uid(), (select module_id from lessons where id = lesson_id))
  );

drop policy if exists "membre annule une leçon vue" on public.lesson_progress;
create policy "membre annule une leçon vue" on public.lesson_progress
  for delete using (member_id = auth.uid());

-- ---------------------------------------------------------------------
-- 6. Premier administrateur
-- ---------------------------------------------------------------------
-- Après avoir créé ton compte via le lien magique, exécute :
--
--   insert into public.members (id, email, first_name, role)
--   select id, email, 'Martin', 'admin' from auth.users where email = 'ton@email.com'
--   on conflict (id) do update set role = 'admin';


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 02-formules.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Formules et liens d'invitation
--  À passer après schema.sql. Rejouable sans risque.
--
--  L'accès d'un membre ne dépend plus d'un simple « activé / pas activé »
--  mais de sa formule : le mensuel ouvre un lot de modules, l'annuel les
--  ouvre tous. La progression continue de gouverner l'ordre à l'intérieur
--  de ce que la formule donne.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Formules
-- ---------------------------------------------------------------------

create table if not exists public.plans (
  code     text primary key,
  label    text not null,
  rank     int  not null default 0
);

insert into public.plans (code, label, rank) values
  ('mensuel', 'Mensuel', 1),
  ('annuel',  'Annuel',  2)
on conflict (code) do update set label = excluded.label, rank = excluded.rank;

-- Quels modules chaque formule contient. Réglable depuis le back-office.
create table if not exists public.plan_modules (
  plan_code text   not null references public.plans(code) on delete cascade,
  module_id bigint not null references public.modules(id) on delete cascade,
  primary key (plan_code, module_id)
);

-- Par défaut l'annuel donne tout ; le mensuel, le premier module. À ajuster
-- dans le back-office, cette ligne ne fait qu'éviter une base vide.
insert into public.plan_modules (plan_code, module_id)
select 'annuel', id from public.modules
on conflict do nothing;

insert into public.plan_modules (plan_code, module_id)
select 'mensuel', id from public.modules where position = 1
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. Le membre porte sa formule
-- ---------------------------------------------------------------------

alter table public.members
  add column if not exists plan_code text references public.plans(code);

-- ---------------------------------------------------------------------
-- 3. Invitations
-- ---------------------------------------------------------------------
-- Le setter génère un lien, le copie, l'envoie lui-même. Le jeton ne sert
-- qu'une fois et expire : un lien qui traîne dans une conversation ne donne
-- pas un accès à vie.

create table if not exists public.invites (
  token       uuid primary key default gen_random_uuid(),
  plan_code   text not null references public.plans(code),
  label       text,                       -- pour que le setter s'y retrouve
  created_by  uuid references public.members(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  used_at     timestamptz,
  used_by     uuid references public.members(id)
);

create index if not exists invites_open_idx on public.invites(used_at, expires_at);

alter table public.invites enable row level security;

drop policy if exists "admin gère les invitations" on public.invites;
create policy "admin gère les invitations" on public.invites
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- Les formules sont lisibles par tout membre connecté (pour afficher la
-- sienne), et modifiables par l'équipe seule.
alter table public.plans        enable row level security;
alter table public.plan_modules enable row level security;

drop policy if exists "lecture des formules" on public.plans;
create policy "lecture des formules" on public.plans
  for select using (auth.uid() is not null);

drop policy if exists "admin gère les formules" on public.plans;
create policy "admin gère les formules" on public.plans
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

drop policy if exists "lecture du contenu des formules" on public.plan_modules;
create policy "lecture du contenu des formules" on public.plan_modules
  for select using (auth.uid() is not null);

drop policy if exists "admin gère le contenu des formules" on public.plan_modules;
create policy "admin gère le contenu des formules" on public.plan_modules
  for all using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- ---------------------------------------------------------------------
-- 4. L'accès dépend maintenant de la formule
-- ---------------------------------------------------------------------

-- Le module fait-il partie de ce que la personne a payé ?
create or replace function public.has_module(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from members m
    join plan_modules pm on pm.plan_code = m.plan_code
    where m.id = p_member and pm.module_id = p_module
  );
$$;

-- Un module s'ouvre quand tous ceux qui le précèdent DANS SA FORMULE sont
-- terminés. Sans ce filtre, un mensuel resterait bloqué derrière un module
-- annuel qu'il ne peut pas voir.
create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select has_module(p_member, p_module)
     and coalesce(bool_and(module_completion(p_member, m.id) >= 1), true)
  from modules m
  where m.position < (select position from modules where id = p_module)
    and has_module(p_member, m.id);
$$;

-- La liste des modules ne montre que ceux de la formule.
create or replace function public.my_modules()
returns table (
  id          bigint,
  "position"  int,
  title       text,
  description text,
  lesson_count int,
  done_count   int,
  completion   numeric,
  unlocked     boolean
)
language sql stable security definer set search_path = public
as $$
  select m.id,
         m.position,
         m.title,
         m.description,
         (select count(*)::int from lessons l where l.module_id = m.id),
         (select count(*)::int
            from lessons l
            join lesson_progress p
              on p.lesson_id = l.id and p.member_id = auth.uid()
           where l.module_id = m.id),
         module_completion(auth.uid(), m.id),
         is_module_unlocked(auth.uid(), m.id)
  from modules m
  where has_module(auth.uid(), m.id) or is_admin(auth.uid())
  order by m.position;
$$;

-- ---------------------------------------------------------------------
-- 5. Les modules de la page « formules » du back-office
-- ---------------------------------------------------------------------

create or replace function public.plan_matrix()
returns table (
  module_id    bigint,
  "position"   int,
  title        text,
  plan_codes   text[]
)
language sql stable security definer set search_path = public
as $$
  select m.id,
         m.position,
         m.title,
         coalesce(array_agg(pm.plan_code order by pm.plan_code)
                  filter (where pm.plan_code is not null), '{}')
  from modules m
  left join plan_modules pm on pm.module_id = m.id
  group by m.id, m.position, m.title
  order by m.position;
$$;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 03-videos.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Vidéos dans Supabase Storage
--  À passer après 02-formules.sql. Rejouable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Le seau
-- ---------------------------------------------------------------------
-- Privé : aucun fichier n'est accessible par son URL. La lecture passe
-- exclusivement par une URL signée que le serveur émet leçon par leçon,
-- après avoir vérifié la formule et la progression.

insert into storage.buckets (id, name, public, file_size_limit)
values ('videos', 'videos', false, 5368709120)  -- 5 Go par fichier
on conflict (id) do update set public = false, file_size_limit = 5368709120;

-- Seule l'équipe dépose ou supprime des fichiers. Personne ne les liste :
-- connaître le nom d'un fichier ne donne rien sans URL signée.
drop policy if exists "équipe dépose les vidéos" on storage.objects;
create policy "équipe dépose les vidéos" on storage.objects
  for insert with check (bucket_id = 'videos' and public.is_admin(auth.uid()));

drop policy if exists "équipe gère les vidéos" on storage.objects;
create policy "équipe gère les vidéos" on storage.objects
  for update using (bucket_id = 'videos' and public.is_admin(auth.uid()));

drop policy if exists "équipe supprime les vidéos" on storage.objects;
create policy "équipe supprime les vidéos" on storage.objects
  for delete using (bucket_id = 'videos' and public.is_admin(auth.uid()));

drop policy if exists "équipe liste les vidéos" on storage.objects;
create policy "équipe liste les vidéos" on storage.objects
  for select using (bucket_id = 'videos' and public.is_admin(auth.uid()));

-- ---------------------------------------------------------------------
-- 2. La leçon pointe vers un chemin, plus vers un identifiant externe
-- ---------------------------------------------------------------------

-- Rejouable : la colonne n'est renommée que si l'ancien nom existe encore.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'lessons' and column_name = 'video_id'
  ) then
    alter table public.lessons rename column video_id to video_path;
  end if;
end $$;

comment on column public.lessons.video_path is
  'Chemin du fichier dans le seau « videos », par exemple module-1/01-introduction.mp4';


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 05-vimeo.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Leçons hébergées sur Vimeo
--  À passer après 04-programme.sql. Rejouable.
--
--  Une leçon a soit un fichier déposé dans Storage (video_path), soit une
--  vidéo Vimeo (vimeo_url). Les deux voies passent par le même contrôle
--  d'accès : l'adresse de lecture n'est renvoyée qu'après vérification de
--  la formule et de la progression.
-- =====================================================================

alter table public.lessons
  add column if not exists vimeo_url text;

comment on column public.lessons.vimeo_url is
  'URL du lecteur Vimeo, hash de partage compris pour les vidéos non répertoriées : https://player.vimeo.com/video/123456789?h=abc123';


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 06-documents.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Leçons accompagnées d'un document
--  À passer après 05-vimeo.sql. Rejouable.
--
--  Une leçon peut désormais porter un PDF : soit à la place de la vidéo
--  (une checklist, un modèle à remplir), soit en plus d'elle. Le fichier
--  vit dans le même seau privé que les vidéos et se lit par une adresse
--  signée, après les mêmes contrôles.
-- =====================================================================

alter table public.lessons
  add column if not exists document_path text,
  add column if not exists document_name text;

comment on column public.lessons.document_path is
  'Chemin du PDF dans le seau « videos ». Une leçon peut n''avoir que ça.';


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 07-outils.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les outils recommandés
--  À passer après 06-documents.sql. Rejouable.
--
--  Une liste d'outils avec leur code promo, visible par tout membre quelle
--  que soit sa formule : ce n'est pas du contenu de cours, c'est de
--  l'équipement. Elle se gère depuis le back-office.
-- =====================================================================

create table if not exists public.tools (
  id          bigint generated always as identity primary key,
  position    int  not null default 0,
  name        text not null,
  description text,
  promo_code  text,
  url         text,
  created_at  timestamptz not null default now()
);

alter table public.tools enable row level security;

drop policy if exists "membre lit les outils" on public.tools;
create policy "membre lit les outils" on public.tools
  for select using (auth.uid() is not null);

drop policy if exists "admin gère les outils" on public.tools;
create policy "admin gère les outils" on public.tools
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 08-acces-equipe.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  L'équipe voit tout
--  À passer après 07-outils.sql. Rejouable.
--
--  is_module_unlocked exigeait une formule. Un administrateur n'en a pas :
--  il voyait donc tous les modules dans la liste, mais tous verrouillés,
--  sans pouvoir relire son propre contenu.
-- =====================================================================

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_admin(p_member)
      or (
        has_module(p_member, p_module)
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
          ),
          true
        )
      );
$$;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 09-ressources.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Ressources : documents à télécharger et prompts à copier
--  À passer après 08-acces-equipe.sql. Rejouable.
--
--  Elles s'affichent sous les modules, pour tout membre quelle que soit sa
--  formule. Un fichier vit dans le seau privé « videos » et se lit par une
--  adresse signée ; un prompt est stocké en clair et se copie d'un clic.
-- =====================================================================

create table if not exists public.resources (
  id          bigint generated always as identity primary key,
  position    int  not null default 0,
  kind        text not null default 'fichier' check (kind in ('fichier', 'prompt')),
  title       text not null,
  description text,
  file_path   text,
  file_name   text,
  prompt_text text,
  created_at  timestamptz not null default now()
);

alter table public.resources enable row level security;

drop policy if exists "membre lit les ressources" on public.resources;
create policy "membre lit les ressources" on public.resources
  for select using (auth.uid() is not null);

drop policy if exists "admin gère les ressources" on public.resources;
create policy "admin gère les ressources" on public.resources
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 10-introduction.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les modules d'introduction
--  À passer après 09-ressources.sql. Rejouable.
--
--  Une introduction ne se mérite pas : elle s'affiche au-dessus du
--  programme, ouverte à tous quelle que soit la formule, et sans attendre
--  qu'un module précédent soit terminé.
-- =====================================================================

alter table public.modules
  add column if not exists is_intro boolean not null default false;

comment on column public.modules.is_intro is
  'Module d''introduction : hors formule, hors déverrouillage, affiché avant le programme.';

-- ---------------------------------------------------------------------
-- L'accès ignore la formule pour ces modules
-- ---------------------------------------------------------------------

create or replace function public.has_module(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from modules where id = p_module and is_intro)
      or exists (
        select 1
        from members m
        join plan_modules pm on pm.plan_code = m.plan_code
        where m.id = p_member and pm.module_id = p_module
      );
$$;

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_admin(p_member)
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        has_module(p_member, p_module)
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
              and not m.is_intro          -- une intro non vue ne bloque rien
          ),
          true
        )
      );
$$;

-- ---------------------------------------------------------------------
-- La liste des modules distingue les deux
-- ---------------------------------------------------------------------

-- Postgres refuse de changer par « create or replace » les colonnes
-- renvoyées par une fonction : il faut la retirer d'abord.
drop function if exists public.my_modules();

create function public.my_modules()
returns table (
  id          bigint,
  "position"  int,
  title       text,
  description text,
  is_intro    boolean,
  lesson_count int,
  done_count   int,
  completion   numeric,
  unlocked     boolean
)
language sql stable security definer set search_path = public
as $$
  select m.id,
         m.position,
         m.title,
         m.description,
         m.is_intro,
         (select count(*)::int from lessons l where l.module_id = m.id),
         (select count(*)::int
            from lessons l
            join lesson_progress p
              on p.lesson_id = l.id and p.member_id = auth.uid()
           where l.module_id = m.id),
         module_completion(auth.uid(), m.id),
         is_module_unlocked(auth.uid(), m.id)
  from modules m
  where has_module(auth.uid(), m.id) or is_admin(auth.uid())
  order by m.is_intro desc, m.position;
$$;

-- Le droit d'exécution se perd avec la fonction supprimée : on le remet.
revoke all on function public.my_modules() from public, anon;
grant execute on function public.my_modules() to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 11-avertissement.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Un avertissement par leçon
--  À passer après 10-introduction.sql. Rejouable.
--
--  De quoi corriger une vidéo sans la retourner : un bandeau rouge sous
--  le titre, au-dessus du lecteur, là où personne ne peut le manquer.
-- =====================================================================

alter table public.lessons
  add column if not exists avertissement text;

comment on column public.lessons.avertissement is
  'Message affiché en rouge au-dessus du lecteur. Sert à rectifier un passage de la vidéo sans avoir à la refaire.';


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 12-equipe-crm.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les comptes du CRM ouvrent aussi l'espace membre
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Le CRM et l'espace membre partagent le même projet Supabase, donc les
--  mêmes comptes. Un setter avait déjà ses identifiants — il lui manquait
--  seulement une fiche `members` et le droit de créer des invitations.
--
--  Il génère désormais ses liens mensuels et annuels lui-même, sans passer
--  par un administrateur. Il ne touche ni au contenu, ni aux formules, ni
--  aux mots de passe des élèves : ça reste réservé aux administrateurs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Un troisième rôle
-- ---------------------------------------------------------------------

alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check
  check (role in ('member', 'setter', 'admin'));

comment on column public.members.role is
  'member = élève ; setter = génère des invitations ; admin = tout.';

create or replace function public.is_equipe(p_user uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from members where id = p_user and role in ('setter', 'admin')
  );
$$;

-- ---------------------------------------------------------------------
-- 2. L'équipe du CRM devient l'équipe de l'espace membre
-- ---------------------------------------------------------------------
-- Une fiche par compte du CRM. Un administrateur du CRM le reste ici, et
-- personne n'est jamais rétrogradé par mégarde.

insert into public.members (id, email, first_name, last_name, role)
select s.user_id, u.email, s.first_name, s.last_name,
       case when s.role = 'admin' then 'admin' else 'setter' end
from public.staff s
join auth.users u on u.id = s.user_id
where s.actif
on conflict (id) do update
  set role = case
               when members.role = 'admin' or excluded.role = 'admin' then 'admin'
               when members.role = 'member' then 'setter'
               else excluded.role
             end,
      first_name = coalesce(members.first_name, excluded.first_name),
      last_name  = coalesce(members.last_name,  excluded.last_name);

-- Et la suite : un compte créé plus tard dans le CRM ouvre l'espace membre
-- sans qu'on ait à repasser par ici.
create or replace function public.staff_vers_membre()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.actif then
    insert into public.members (id, email, first_name, last_name, role)
    select new.user_id, u.email, new.first_name, new.last_name,
           case when new.role = 'admin' then 'admin' else 'setter' end
    from auth.users u
    where u.id = new.user_id
    on conflict (id) do update
      set role = case
                   when excluded.role = 'admin' then 'admin'
                   when members.role = 'member' then 'setter'
                   else excluded.role
                 end;
  else
    -- Quelqu'un qui quitte l'équipe ne garde pas le back-office. On lui
    -- laisse sa fiche : la retirer effacerait sa progression s'il était
    -- aussi élève.
    update public.members set role = 'member' where id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_staff_vers_membre on public.staff;
create trigger trg_staff_vers_membre
  after insert or update of role, actif, first_name, last_name on public.staff
  for each row execute function public.staff_vers_membre();

-- ---------------------------------------------------------------------
-- 3. Les invitations passent de « admin » à « équipe »
-- ---------------------------------------------------------------------
-- C'est le seul droit qu'un setter gagne. Formules, contenu, outils,
-- ressources et mots de passe restent aux administrateurs.

drop policy if exists "admin gère les invitations" on public.invites;
drop policy if exists "equipe gère les invitations" on public.invites;
create policy "equipe gère les invitations" on public.invites
  for all to authenticated
  using (public.is_equipe(auth.uid()))
  with check (public.is_equipe(auth.uid()));

-- ---------------------------------------------------------------------
-- 4. L'équipe voit le programme
-- ---------------------------------------------------------------------
-- Un setter vend le programme : il doit pouvoir le regarder. Même règle
-- que pour les administrateurs, posée en 08-acces-equipe.sql.

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        has_module(p_member, p_module)
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
              and not m.is_intro          -- une intro non vue ne bloque rien
          ),
          true
        )
      );
$$;

drop function if exists public.my_modules();

create function public.my_modules()
returns table (
  id          bigint,
  "position"  int,
  title       text,
  description text,
  is_intro    boolean,
  lesson_count int,
  done_count   int,
  completion   numeric,
  unlocked     boolean
)
language sql stable security definer set search_path = public
as $$
  select m.id, m.position, m.title, m.description, m.is_intro,
         (select count(*)::int from lessons l where l.module_id = m.id),
         (select count(*)::int from lessons l
            join lesson_progress p on p.lesson_id = l.id and p.member_id = auth.uid()
           where l.module_id = m.id),
         module_completion(auth.uid(), m.id),
         is_module_unlocked(auth.uid(), m.id)
  from modules m
  where has_module(auth.uid(), m.id) or is_equipe(auth.uid())
  order by m.is_intro desc, m.position;
$$;

revoke all on function public.my_modules() from public, anon;
grant execute on function public.my_modules() to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 14-porte-introduction.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Trois portes avant le programme
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  L'élève regarde les deux vidéos d'introduction, construit son outil sur
--  Base44, et en dépose une photo. Tant que les trois ne sont pas faites,
--  aucun module du programme ne s'ouvre.
--
--  Le verrou vit ici et pas dans la page : la policy des leçons appelle
--  is_module_unlocked, donc une leçon verrouillée n'est pas renvoyée du
--  tout — identifiant vidéo compris. Bidouiller le JavaScript ne donne
--  accès à rien.
--
--  Même règle en mensuel et en annuel. L'équipe n'est pas concernée :
--  elle doit pouvoir relire le programme sans refaire l'exercice.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Le seau des preuves
-- ---------------------------------------------------------------------
-- Privé : la capture d'écran d'un élève ne regarde que lui et l'équipe.

insert into storage.buckets (id, name, public, file_size_limit)
values ('preuves', 'preuves', false, 10485760)   -- 10 Mo, large pour une capture
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists "preuve deposee" on storage.objects;
create policy "preuve deposee" on storage.objects
  for insert with check (
    bucket_id = 'preuves'
    and auth.uid() is not null
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "preuve lue" on storage.objects;
create policy "preuve lue" on storage.objects
  for select using (
    bucket_id = 'preuves'
    and (public.is_equipe(auth.uid()) or (storage.foldername(name))[1] = auth.uid()::text)
  );

drop policy if exists "preuve remplacee" on storage.objects;
create policy "preuve remplacee" on storage.objects
  for delete using (
    bucket_id = 'preuves'
    and (public.is_admin(auth.uid()) or (storage.foldername(name))[1] = auth.uid()::text)
  );

-- ---------------------------------------------------------------------
-- 2. La preuve
-- ---------------------------------------------------------------------
-- Une par élève : redéposer remplace. Le dépôt ouvre le programme
-- immédiatement — personne n'attend un feu vert à deux heures du matin —
-- et un administrateur peut refuser après coup, ce qui reverrouille.

create table if not exists public.preuves (
  member_id   uuid primary key references public.members(id) on delete cascade,
  file_path   text not null,
  file_name   text,
  taille      int,
  statut      text not null default 'deposee'
              check (statut in ('deposee', 'validee', 'refusee')),
  motif       text,               -- ce qu'on reproche, quand on refuse
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists preuves_statut_idx on public.preuves (statut, created_at desc);

create or replace function public.toucher_preuve()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_toucher_preuve on public.preuves;
create trigger trg_toucher_preuve
  before update on public.preuves
  for each row execute function public.toucher_preuve();

alter table public.preuves enable row level security;

drop policy if exists "eleve voit sa preuve" on public.preuves;
create policy "eleve voit sa preuve" on public.preuves
  for select to authenticated
  using (member_id = auth.uid() or public.is_equipe(auth.uid()));

-- Déposer, oui ; se valider soi-même, non.
drop policy if exists "eleve depose sa preuve" on public.preuves;
create policy "eleve depose sa preuve" on public.preuves
  for insert to authenticated
  with check (member_id = auth.uid() and statut = 'deposee');

drop policy if exists "eleve remplace sa preuve" on public.preuves;
create policy "eleve remplace sa preuve" on public.preuves
  for update to authenticated
  using (member_id = auth.uid() or public.is_admin(auth.uid()))
  with check (public.is_admin(auth.uid()) or (member_id = auth.uid() and statut = 'deposee'));

-- ---------------------------------------------------------------------
-- 3. Les deux conditions
-- ---------------------------------------------------------------------

create or replace function public.intro_terminee(p_member uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  -- Vrai quand toutes les leçons des modules d'introduction sont vues.
  -- Vrai aussi s'il n'y a pas d'introduction : on ne bloque pas sur rien.
  select not exists (
    select 1
    from lessons l
    join modules m on m.id = l.module_id
    where m.is_intro
      and not exists (
        select 1 from lesson_progress p
        where p.lesson_id = l.id and p.member_id = p_member
      )
  );
$$;

create or replace function public.preuve_deposee(p_member uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from preuves
    where member_id = p_member and statut <> 'refusee'
  );
$$;

-- ---------------------------------------------------------------------
-- 4. Le verrou
-- ---------------------------------------------------------------------

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Les trois portes, avant toute chose.
        intro_terminee(p_member)
        and preuve_deposee(p_member)
        and has_module(p_member, p_module)
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
              and not m.is_intro          -- une intro non vue ne bloque pas ici
          ),
          true
        )
      );
$$;

-- ---------------------------------------------------------------------
-- 5. Où en est chaque élève, pour le back-office
-- ---------------------------------------------------------------------

create or replace function public.etat_portes()
returns table (
  member_id  uuid,
  first_name text,
  email      text,
  plan_code  text,
  intro_ok   boolean,
  preuve     text,
  file_path  text,
  depose_le  timestamptz
)
language sql stable security invoker set search_path = public
as $$
  select m.id, m.first_name, m.email, m.plan_code,
         intro_terminee(m.id),
         coalesce(p.statut, 'aucune'),
         p.file_path,
         p.created_at
  from members m
  left join preuves p on p.member_id = m.id
  where m.role = 'member'
  order by p.created_at desc nulls last, m.activated_at desc;
$$;

revoke all on function public.etat_portes() from public, anon;
grant execute on function public.etat_portes() to authenticated;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 15-prochaines-etapes.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les prochaines étapes
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Une fois son programme terminé, l'élève se voit proposer
--  l'accompagnement 1-1. Pas plus tôt : une offre payante mise en avant
--  au milieu d'un programme annoncé gratuit donne une cible à
--  l'objection « où est le piège ? ».
--
--  « Terminé » se compte sur la formule de chacun : un mensuel n'a pas
--  tous les modules, il n'a pas à passer à l'annuel pour voir la suite.
--
--  Une seule ligne, modifiable depuis le back-office : le texte d'une
--  offre change plus souvent que le code qui l'affiche.
-- =====================================================================

create table if not exists public.prochaines_etapes (
  id          int primary key default 1 check (id = 1),
  actif       boolean not null default true,
  eyebrow     text,
  titre       text not null,
  texte       text,
  cta_libelle text not null,
  cta_url     text not null,
  note        text,
  updated_at  timestamptz not null default now()
);

insert into public.prochaines_etapes (id, actif, eyebrow, titre, texte, cta_libelle, cta_url, note)
values (
  1,
  false,   -- éteint tant que l'offre et son lien ne sont pas renseignés (back-office)
  'Les prochaines étapes',
  'Tu as fini le programme. On peut aller plus loin ensemble.',
  '[À COMPLÉTER depuis le back-office : l''offre d''accompagnement de Sirius]',
  'Réserver mon appel',
  '#',
  null
)
on conflict (id) do nothing;   -- rejouable sans écraser vos retouches

create or replace function public.toucher_etapes()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_toucher_etapes on public.prochaines_etapes;
create trigger trg_toucher_etapes
  before update on public.prochaines_etapes
  for each row execute function public.toucher_etapes();

alter table public.prochaines_etapes enable row level security;

-- Tout membre connecté peut la lire ; c'est la page qui décide de
-- l'afficher, quand le programme est fini.
drop policy if exists "lecture des prochaines etapes" on public.prochaines_etapes;
create policy "lecture des prochaines etapes" on public.prochaines_etapes
  for select using (auth.uid() is not null);

drop policy if exists "admin gere les prochaines etapes" on public.prochaines_etapes;
create policy "admin gere les prochaines etapes" on public.prochaines_etapes
  for all using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 19-workshop.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le workshop 7 jours
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Après les vidéos d'introduction, l'élève construit son outil Base44
--  sur sept jours : un prompt par jour, une vidéo par jour. Un jour se
--  débloque à minuit, heure de Paris — entré à 18 h, il a le jour 1 à
--  minuit, le jour 2 le lendemain, et ainsi de suite.
--
--  Le programme vidéo, lui, ne change pas : mensuel et annuel gardent ce
--  qu'ils ont. Une seule nuance : avant le jour 3 du workshop, seuls les
--  premiers modules sont ouverts ; au jour 3, tout le reste se débloque
--  selon la formule de chacun.
--
--  Les élèves déjà inscrits ne sont bloqués par rien : ils sont marqués
--  « dispensés », voient les sept jours d'un coup, et gardent l'accès
--  complet à leur programme.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Les réglages
-- ---------------------------------------------------------------------
-- Dans une table, pas dans le code : le jour du déblocage complet et le
-- nombre de modules ouverts avant se changent sans redéploiement.

create table if not exists public.workshop_reglages (
  id                  int primary key check (id = 1),
  modules_avant_j3    int  not null default 1,   -- combien de modules avant le jour 3
  jour_deblocage      int  not null default 3,   -- le jour qui ouvre tout le reste
  fuseau              text not null default 'Europe/Paris',
  bandeau_actif       boolean not null default true,
  bandeau_texte       text not null default 'Nouveau : le workshop en 7 jours est disponible.',
  bandeau_lien_texte  text not null default 'Voir les 7 jours',
  updated_at          timestamptz not null default now()
);

insert into public.workshop_reglages (id) values (1) on conflict (id) do nothing;

alter table public.workshop_reglages enable row level security;

drop policy if exists "tout le monde lit les reglages" on public.workshop_reglages;
create policy "tout le monde lit les reglages" on public.workshop_reglages
  for select to authenticated using (auth.uid() is not null);

drop policy if exists "admin modifie les reglages" on public.workshop_reglages;
create policy "admin modifie les reglages" on public.workshop_reglages
  for all to authenticated using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------------------------------------------------------------------
-- 2. Les sept jours
-- ---------------------------------------------------------------------
-- Un jour = une vidéo, un ou deux prompts, et quelques consignes. Le
-- contenu se remplit depuis le back-office.

create table if not exists public.workshop_jours (
  jour        int primary key check (jour between 1 and 7),
  titre       text not null,
  resume      text,                 -- ce qu'on construit aujourd'hui
  video_url   text,                 -- Loom, Vimeo ou autre lecteur
  prompt      text,                 -- le prompt à copier
  prompt_2    text,                 -- le deuxième prompt, pour le jour 2
  prompt_2_titre text,
  consignes   text,                 -- à faire avant demain
  updated_at  timestamptz not null default now()
);

insert into public.workshop_jours (jour, titre, resume) values
  (1, 'Jour 1', null),
  (2, 'Jour 2', null),
  (3, 'Jour 3', null),
  (4, 'Jour 4', null),
  (5, 'Jour 5', null),
  (6, 'Jour 6', null),
  (7, 'Jour 7', null)
on conflict (jour) do nothing;

alter table public.workshop_jours enable row level security;

drop policy if exists "admin gere les jours" on public.workshop_jours;
create policy "admin gere les jours" on public.workshop_jours
  for all to authenticated using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---------------------------------------------------------------------
-- 3. Où en est l'élève
-- ---------------------------------------------------------------------
-- `workshop_debut_at` est posé au moment où les vidéos d'introduction
-- sont terminées : c'est de là que partent les minuits.
-- `workshop_dispense` : les élèves d'avant, qui ne doivent rien attendre.

alter table public.members
  add column if not exists workshop_debut_at  timestamptz,
  add column if not exists workshop_dispense  boolean not null default false;

-- Les élèves déjà inscrits au moment de cette migration sont dispensés.
-- Le repère est la date : tous ceux qui existent aujourd'hui.
update public.members
   set workshop_dispense = true
 where activated_at < now()
   and workshop_debut_at is null;

-- ---------------------------------------------------------------------
-- 4. Le jour débloqué
-- ---------------------------------------------------------------------
-- On compte les minuits franchis depuis le départ, heure de Paris : entré
-- à 18 h, l'élève a le jour 1 au minuit suivant. Un dispensé a les sept.

create or replace function public.workshop_jour(p_member uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select case
    when p_member is null then 0
    when is_equipe(p_member) then 7
    when exists (select 1 from members where id = p_member and workshop_dispense) then 7
    else coalesce(
      (
        select least(
          7,
          greatest(
            0,
            (
              ( (now() at time zone (select fuseau from workshop_reglages where id = 1))::date
              - (m.workshop_debut_at at time zone (select fuseau from workshop_reglages where id = 1))::date )
            )::int
          )
        )
        from members m
        where m.id = p_member and m.workshop_debut_at is not null
      ),
      0
    )
  end;
$$;

revoke all on function public.workshop_jour(uuid) from public, anon;
grant execute on function public.workshop_jour(uuid) to authenticated;

-- Le départ se pose tout seul à la première lecture, dès que les vidéos
-- d'introduction sont terminées. Appelée par la page au chargement.

create or replace function public.workshop_demarrer()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_jour int;
begin
  update public.members
     set workshop_debut_at = now()
   where id = auth.uid()
     and workshop_debut_at is null
     and not workshop_dispense
     and public.intro_terminee(auth.uid());

  select public.workshop_jour(auth.uid()) into v_jour;
  return v_jour;
end;
$$;

revoke all on function public.workshop_demarrer() from public, anon;
grant execute on function public.workshop_demarrer() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Ce que l'élève reçoit
-- ---------------------------------------------------------------------
-- Les jours à venir existent, mais leur vidéo et leurs prompts sont
-- remplacés par null : le contenu ne part pas dans le navigateur avant
-- l'heure. L'heure exacte du prochain déblocage est renvoyée pour
-- afficher un compte à rebours juste.

create or replace function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz
)
language sql stable security definer set search_path = public
as $$
  with r as (select fuseau from workshop_reglages where id = 1),
       e as (
         select public.workshop_jour(auth.uid()) as jour_max,
                (select workshop_debut_at from members where id = auth.uid()) as debut,
                (select workshop_dispense  from members where id = auth.uid()) as dispense
       )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           -- minuit, heure de Paris, après (jour - 1) nuits depuis le départ
           else ((((e.debut at time zone (select fuseau from r))::date
                   + j.jour) :: timestamp) at time zone (select fuseau from r))
         end
  from workshop_jours j, e
  order by j.jour;
$$;

revoke all on function public.mon_workshop() from public, anon;
grant execute on function public.mon_workshop() to authenticated;

-- ---------------------------------------------------------------------
-- 6. Les modules du programme suivent le workshop
-- ---------------------------------------------------------------------
-- Rien ne change pour les formules : chacun garde ses modules. Avant le
-- jour 3, seuls les premiers sont ouverts ; au jour 3, tout le reste
-- s'ouvre. L'équipe et les dispensés ne sont pas concernés.

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Les trois portes, avant toute chose.
        intro_terminee(p_member)
        and preuve_deposee(p_member)
        and has_module(p_member, p_module)
        -- Le palier du workshop : avant le jour 3, seuls les premiers
        -- modules. Un dispensé a workshop_jour = 7, donc rien ne change
        -- pour lui.
        and (
          workshop_jour(p_member) >= (select jour_deblocage from workshop_reglages where id = 1)
          or (
            select count(*) from modules m2
            where not m2.is_intro
              and m2.position <= (select position from modules where id = p_module)
          ) <= (select modules_avant_j3 from workshop_reglages where id = 1)
        )
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
              and not m.is_intro
          ),
          true
        )
      );
$$;

-- ---------------------------------------------------------------------
-- 7. Vérification
-- ---------------------------------------------------------------------

select (select count(*) from public.members where workshop_dispense) as anciens_dispenses,
       (select count(*) from public.workshop_jours)                   as jours_crees,
       (select modules_avant_j3 from public.workshop_reglages where id = 1) as modules_avant_j3;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 20-sans-preuve.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  La photo Base44 n'est plus une porte
--  À passer APRÈS 19-workshop.sql. Rejouable.
--
--  Avant le workshop, on demandait à l'élève une photo de son outil pour
--  ouvrir le programme : c'était la preuve qu'il s'était servi de Base44.
--  Le workshop 7 jours joue ce rôle désormais, et bien mieux — il ne
--  prouve pas seulement qu'il a construit l'outil, il le lui fait
--  construire.
--
--  Deux portes restent : les vidéos d'introduction, et le palier du jour
--  3 du workshop. La photo devient facultative ; la table et la page
--  restent en place, elles ne bloquent plus rien.
-- =====================================================================

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Première porte : les vidéos d'introduction, toujours obligatoires.
        intro_terminee(p_member)
        and has_module(p_member, p_module)
        -- Seconde porte : le palier du workshop. Avant le jour de
        -- déblocage, seuls les premiers modules. Un élève dispensé a
        -- workshop_jour = 7, donc rien ne change pour lui.
        and (
          workshop_jour(p_member) >= (select jour_deblocage from workshop_reglages where id = 1)
          or (
            select count(*) from modules m2
            where not m2.is_intro
              and m2.position <= (select position from modules where id = p_module)
          ) <= (select modules_avant_j3 from workshop_reglages where id = 1)
        )
        -- Et toujours la progression : un module s'ouvre quand le
        -- précédent est terminé.
        and coalesce(
          (
            select bool_and(module_completion(p_member, m.id) >= 1)
            from modules m
            where m.position < (select position from modules where id = p_module)
              and has_module(p_member, m.id)
              and not m.is_intro
          ),
          true
        )
      );
$$;

-- Vérification : un élève qui a vu ses introductions et dont le workshop
-- est au jour 3 doit avoir ses modules ouverts.
select m.email,
       public.intro_terminee(m.id)  as intro_ok,
       public.workshop_jour(m.id)   as jour_workshop,
       (select count(*) from public.modules mo
         where not mo.is_intro and public.is_module_unlocked(m.id, mo.id)) as modules_ouverts
from public.members m
order by m.activated_at desc
limit 10;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 21-workshop-rythme.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le rythme du workshop : jour 1 tout de suite, programme au jour 3
--  À passer APRÈS 20-sans-preuve.sql. Rejouable.
--
--  Le rythme retenu :
--
--  - Le jour 0 du workshop est fait avec le setter pendant l'appel : en
--    arrivant sur l'espace membre, l'élève a déjà prompté une fois.
--  - Le premier module du programme est donc ouvert tout de suite : il
--    peut commencer sans attendre.
--  - Le jour 1 du workshop s'ouvre au minuit suivant, le jour 2 le
--    lendemain, et ainsi de suite.
--  - Au jour 3, tout le reste du programme s'ouvre, selon sa formule.
--
--  Cette migration ne change donc pas le calcul des jours : elle fixe le
--  réglage des modules et ajoute une fonction d'état pour l'affichage.
-- =====================================================================

-- Le premier module reste ouvert dès l'inscription : le jour 0 a déjà été
-- fait avec le setter pendant l'appel, l'élève a déjà prompté. Il peut
-- donc commencer le programme tout de suite, et le setter lui a annoncé le
-- jour 1 pour le lendemain.
update public.workshop_reglages
   set modules_avant_j3 = 1,
       jour_deblocage   = 3,
       updated_at       = now()
 where id = 1;

-- ---------------------------------------------------------------------
-- Où en est l'élève, pour l'affichage du programme
-- ---------------------------------------------------------------------
-- Une seule fonction que la page appelle pour savoir quoi dire : son jour,
-- le jour qui ouvre le programme, et quand ce jour arrive.

create or replace function public.mon_etat_workshop()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'jour',            public.workshop_jour(auth.uid()),
    'jour_deblocage',  (select jour_deblocage from workshop_reglages where id = 1),
    'dispense',        coalesce((select workshop_dispense from members where id = auth.uid()), false),
    'equipe',          public.is_equipe(auth.uid()),
    'intro_ok',        public.intro_terminee(auth.uid()),
    'ouvre_le',        (
      select case
        when public.workshop_jour(auth.uid()) >= (select jour_deblocage from workshop_reglages where id = 1) then null
        when m.workshop_debut_at is null then null
        else ((((m.workshop_debut_at at time zone (select fuseau from workshop_reglages where id = 1))::date
                + ((select jour_deblocage from workshop_reglages where id = 1) - 1)) :: timestamp)
               at time zone (select fuseau from workshop_reglages where id = 1))
      end
      from members m where m.id = auth.uid()
    )
  );
$$;

revoke all on function public.mon_etat_workshop() from public, anon;
grant execute on function public.mon_etat_workshop() to authenticated;

-- Vérification : les dix derniers inscrits.
select m.email,
       public.intro_terminee(m.id) as intro_ok,
       m.workshop_dispense         as dispense,
       public.workshop_jour(m.id)  as jour,
       (select count(*) from public.modules mo
         where not mo.is_intro and public.is_module_unlocked(m.id, mo.id)) as modules_ouverts
from public.members m
order by m.activated_at desc
limit 10;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 22-fuseau-eleve.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Minuit chez l'élève, pas minuit à Paris
--  À passer APRÈS 21-workshop-rythme.sql. Rejouable.
--
--  Le workshop ouvrait ses jours à minuit, heure de Paris. Pour un élève
--  au Mexique, son jour suivant s'ouvrait donc à 17 h de l'après-midi, et
--  le compte à rebours affichait des heures incompréhensibles.
--
--  Chaque élève a maintenant son propre fuseau, relevé par son navigateur
--  à sa première visite. Le réglage « Europe/Paris » reste le repli pour
--  ceux dont on ne sait rien.
-- =====================================================================

alter table public.members
  add column if not exists fuseau text;

-- Le fuseau de l'élève, ou celui par défaut.
create or replace function public.fuseau_membre(p_member uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select nullif(trim(fuseau), '') from members where id = p_member),
    (select fuseau from workshop_reglages where id = 1),
    'Europe/Paris'
  );
$$;

-- ---------------------------------------------------------------------
-- Le jour en cours, compté dans le fuseau de l'élève
-- ---------------------------------------------------------------------

create or replace function public.workshop_jour(p_member uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select case
    when p_member is null then 0
    when is_equipe(p_member) then 7
    when exists (select 1 from members where id = p_member and workshop_dispense) then 7
    else coalesce(
      (
        select least(
          7,
          greatest(
            0,
            ( (now() at time zone public.fuseau_membre(p_member))::date
            - (m.workshop_debut_at at time zone public.fuseau_membre(p_member))::date )::int
          )
        )
        from members m
        where m.id = p_member and m.workshop_debut_at is not null
      ),
      0
    )
  end;
$$;

-- ---------------------------------------------------------------------
-- Le départ, avec le fuseau du navigateur
-- ---------------------------------------------------------------------
-- La page envoie le fuseau détecté chez l'élève. On l'enregistre à la
-- première visite, et on le rafraîchit s'il change de pays.

create or replace function public.workshop_demarrer(p_fuseau text default null)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_jour int;
begin
  -- Un fuseau n'est accepté que s'il existe vraiment : sinon toutes les
  -- dates calculées plus bas échoueraient.
  if p_fuseau is not null and exists (select 1 from pg_timezone_names where name = p_fuseau) then
    update public.members set fuseau = p_fuseau
     where id = auth.uid()
       and (fuseau is distinct from p_fuseau);
  end if;

  update public.members
     set workshop_debut_at = now()
   where id = auth.uid()
     and workshop_debut_at is null
     and not workshop_dispense
     and public.intro_terminee(auth.uid());

  select public.workshop_jour(auth.uid()) into v_jour;
  return v_jour;
end;
$$;

revoke all on function public.workshop_demarrer(text) from public, anon;
grant execute on function public.workshop_demarrer(text) to authenticated;

-- ---------------------------------------------------------------------
-- Les heures d'ouverture, dans le fuseau de l'élève
-- ---------------------------------------------------------------------

create or replace function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz
)
language sql stable security definer set search_path = public
as $$
  with e as (
    select public.workshop_jour(auth.uid())    as jour_max,
           public.fuseau_membre(auth.uid())    as tz,
           (select workshop_debut_at from members where id = auth.uid()) as debut,
           (select workshop_dispense  from members where id = auth.uid()) as dispense
  )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           -- minuit chez l'élève, après j.jour nuits depuis son départ
           else ((((e.debut at time zone e.tz)::date + j.jour)::timestamp) at time zone e.tz)
         end
  from workshop_jours j, e
  order by j.jour;
$$;

create or replace function public.mon_etat_workshop()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'jour',           public.workshop_jour(auth.uid()),
    'jour_deblocage', (select jour_deblocage from workshop_reglages where id = 1),
    'dispense',       coalesce((select workshop_dispense from members where id = auth.uid()), false),
    'equipe',         public.is_equipe(auth.uid()),
    'intro_ok',       public.intro_terminee(auth.uid()),
    'fuseau',         public.fuseau_membre(auth.uid()),
    'ouvre_le',       (
      select case
        when public.workshop_jour(auth.uid()) >= (select jour_deblocage from workshop_reglages where id = 1) then null
        when m.workshop_debut_at is null then null
        else ((((m.workshop_debut_at at time zone public.fuseau_membre(auth.uid()))::date
                + (select jour_deblocage from workshop_reglages where id = 1))::timestamp)
               at time zone public.fuseau_membre(auth.uid()))
      end
      from members m where m.id = auth.uid()
    )
  );
$$;

-- L'ancienne signature sans argument n'a plus lieu d'être.
drop function if exists public.workshop_demarrer();

-- Vérification : les derniers inscrits, avec leur fuseau.
select m.email, m.fuseau, m.workshop_debut_at,
       public.workshop_jour(m.id) as jour
from public.members m
where m.workshop_debut_at is not null
order by m.workshop_debut_at desc
limit 10;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 23-prompt-j0.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le prompt du jour 0, à portée du setter
--  À passer APRÈS 22-fuseau-eleve.sql. Rejouable.
--
--  Le jour 0 se colle pendant l'appel. Le setter génère le lien
--  d'invitation, et juste en dessous il a le prompt à envoyer — plus
--  besoin d'aller le chercher ailleurs ni de garder une version périmée
--  dans ses notes.
--
--  Il vit dans la table des réglages : un administrateur le modifie
--  depuis le back-office, et tous les setters ont la nouvelle version à
--  la seconde suivante.
-- =====================================================================

alter table public.workshop_reglages
  add column if not exists prompt_j0 text;

-- Le texte du prompt se saisit dans le back-office (Workshop 7 jours).

-- Vérification : la longueur du prompt enregistré.
select length(prompt_j0) as caracteres_prompt_j0 from public.workshop_reglages where id = 1;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 24-guide-bienvenue.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le guide de bienvenue, et le tour de l'espace membre
--  À passer APRÈS 23-prompt-j0.sql. Rejouable.
--
--  Jusqu'ici, l'élève qui venait de créer son accès tombait directement
--  dans l'espace membre, sans savoir par où commencer : il ne voyait pas
--  que la vidéo d'introduction était obligatoire, et il ignorait souvent
--  qu'un prompt l'attendait pour construire son outil.
--
--  Il passe maintenant par trois cartes, posées sur l'espace membre
--  flouté : la bienvenue, le prompt du jour 0, puis la vidéo. Le tour
--  guidé prend le relais une fois qu'il est entré.
--
--  Ce qui ouvre réellement le programme n'a pas changé : c'est toujours
--  intro_terminee(), donc la vidéo vue. Le guide n'est pas un verrou de
--  plus, c'est le chemin par lequel on la regarde.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Ce qu'on retient de chaque élève
-- ---------------------------------------------------------------------
-- `guide_etape` permet de reprendre où il s'est arrêté : il ferme
-- l'onglet au milieu, il revient au même endroit.

alter table public.members
  add column if not exists guide_etape   int not null default 0,
  add column if not exists guide_fait_at timestamptz,
  add column if not exists prompt_recu   boolean,
  add column if not exists tour_fait_at  timestamptz;

comment on column public.members.prompt_recu is
  'Réponse à « ton associé t''a-t-il donné le prompt du jour 0 ? ». '
  'null = la question n''a pas encore été posée. false = le guide le lui a montré.';

-- Les élèves déjà inscrits n'ont pas à revoir une bienvenue : pour eux
-- le guide est réputé fait. Sans cette ligne, les 422 comptes existants
-- se retrouveraient devant la carte 1 à leur prochaine visite.
update public.members
   set guide_fait_at = coalesce(guide_fait_at, now()),
       tour_fait_at  = coalesce(tour_fait_at, now()),
       guide_etape   = greatest(guide_etape, 3)
 where guide_fait_at is null
   and activated_at < now() - interval '1 minute';

-- ---------------------------------------------------------------------
-- 2. Ce que la page demande au chargement
-- ---------------------------------------------------------------------
-- Une seule requête : l'état du guide, le prompt à montrer si besoin, et
-- la leçon d'introduction à lire. Le prompt ne part pas dans le
-- navigateur de quelqu'un qui n'en est pas là.

create or replace function public.mon_guide()
returns json
language sql stable security definer set search_path = public
as $$
  with moi as (
    select m.*, public.is_equipe(m.id) as equipe
      from public.members m
     where m.id = auth.uid()
  ),
  -- Toutes les vidéos d'introduction, dans l'ordre : ce sont elles qui
  -- ouvrent le programme, et le guide les enchaîne. S'il n'en jouait
  -- qu'une alors qu'il y en a deux, le programme resterait fermé derrière.
  intro as (
    select l.id, l.title
      from public.lessons l
      join public.modules mo on mo.id = l.module_id
     where mo.is_intro
     order by mo.position, l.position
  )
  select json_build_object(
    -- L'équipe et les élèves déjà passés n'ont rien à revoir.
    'a_faire',      (select guide_fait_at is null and not equipe from moi),
    'etape',        (select guide_etape from moi),
    'prompt_recu',  (select prompt_recu from moi),
    'tour_a_faire', (select guide_fait_at is not null and tour_fait_at is null and not equipe from moi),
    'prenom',       (select first_name from moi),
    -- Le prompt n'accompagne la réponse que tant que le guide est en cours.
    'prompt_j0',    case when (select guide_fait_at is null and not equipe from moi)
                         then (select prompt_j0 from public.workshop_reglages where id = 1)
                    end,
    'lecons_intro', (select coalesce(json_agg(json_build_object('id', id, 'title', title)), '[]'::json) from intro)
  );
$$;

revoke all on function public.mon_guide() from public, anon;
grant execute on function public.mon_guide() to authenticated;

-- ---------------------------------------------------------------------
-- 3. Ce que la page enregistre
-- ---------------------------------------------------------------------
-- Une fonction par geste, plutôt qu'un update ouvert sur la table : un
-- élève ne doit pas pouvoir se déclarer dispensé du workshop en
-- bidouillant une requête.

create or replace function public.guide_avancer(p_etape int, p_prompt_recu boolean default null)
returns void
language sql volatile security definer set search_path = public
as $$
  update public.members
     set guide_etape = greatest(guide_etape, least(greatest(p_etape, 0), 3)),
         prompt_recu = coalesce(p_prompt_recu, prompt_recu)
   where id = auth.uid();
$$;

revoke all on function public.guide_avancer(int, boolean) from public, anon;
grant execute on function public.guide_avancer(int, boolean) to authenticated;

-- Le guide se referme sur la vidéo vue. On ne la vérifie pas ici : c'est
-- `lesson_progress` qui fait foi, et c'est lui qui ouvre le programme.
create or replace function public.guide_termine()
returns void
language sql volatile security definer set search_path = public
as $$
  update public.members
     set guide_fait_at = coalesce(guide_fait_at, now()),
         guide_etape   = 3
   where id = auth.uid();
$$;

revoke all on function public.guide_termine() from public, anon;
grant execute on function public.guide_termine() to authenticated;

create or replace function public.tour_termine()
returns void
language sql volatile security definer set search_path = public
as $$
  update public.members
     set tour_fait_at = coalesce(tour_fait_at, now())
   where id = auth.uid();
$$;

revoke all on function public.tour_termine() from public, anon;
grant execute on function public.tour_termine() to authenticated;

-- Vérification.
select count(*) filter (where guide_fait_at is null) as guides_a_faire,
       count(*) filter (where prompt_recu is false)  as prompt_montre_par_le_guide,
       count(*)                                      as eleves
  from public.members;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 25-guide-preuve.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le guide, deuxième passe : la preuve de l'outil, la vidéo libre
--  À passer APRÈS 24-guide-bienvenue.sql. Rejouable.
--
--  Deux changements voulus après le premier essai :
--
--  1. L'élève qui répond « non, je n'ai pas collé le prompt » ne passe
--     plus d'un clic. Il va créer son outil dans Base44 et dépose une
--     capture d'écran ; c'est elle qui ouvre la suite. Celui qui répond
--     « oui » continue directement.
--
--  2. La vidéo d'introduction n'est plus obligatoire. Or c'est elle qui
--     ouvrait le programme : si on ne la regarde pas, tout reste fermé
--     derrière. La fin du guide marque donc les vidéos d'introduction
--     comme vues, et c'est le guide — non la vidéo — qui ouvre l'espace.
--
--  La preuve réutilise la table `preuves` : même seau, mêmes règles, même
--  écran de contrôle côté équipe. Rien de neuf à surveiller.
-- =====================================================================

create or replace function public.guide_termine()
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.members
     set guide_fait_at = coalesce(guide_fait_at, now()),
         guide_etape   = 3
   where id = auth.uid();

  -- La vidéo n'étant plus une porte, c'est la fin du guide qui ouvre le
  -- programme. Sans ces lignes, l'élève qui ne la regarde pas trouverait
  -- tous ses modules verrouillés sans comprendre pourquoi.
  insert into public.lesson_progress (member_id, lesson_id)
  select auth.uid(), l.id
    from public.lessons l
    join public.modules m on m.id = l.module_id
   where m.is_intro
  on conflict (member_id, lesson_id) do nothing;
end;
$$;

revoke all on function public.guide_termine() from public, anon;
grant execute on function public.guide_termine() to authenticated;

-- L'état du guide dit maintenant si la capture est déjà déposée : l'élève
-- qui ferme l'onglet au milieu ne la redépose pas.

create or replace function public.mon_guide()
returns json
language sql stable security definer set search_path = public
as $$
  with moi as (
    select m.*, public.is_equipe(m.id) as equipe
      from public.members m
     where m.id = auth.uid()
  ),
  intro as (
    select l.id, l.title
      from public.lessons l
      join public.modules mo on mo.id = l.module_id
     where mo.is_intro
     order by mo.position, l.position
  )
  select json_build_object(
    'a_faire',      (select guide_fait_at is null and not equipe from moi),
    'etape',        (select guide_etape from moi),
    'prompt_recu',  (select prompt_recu from moi),
    'tour_a_faire', (select guide_fait_at is not null and tour_fait_at is null and not equipe from moi),
    'prenom',       (select first_name from moi),
    'preuve_faite', exists (select 1 from public.preuves where member_id = auth.uid()),
    'prompt_j0',    case when (select guide_fait_at is null and not equipe from moi)
                         then (select prompt_j0 from public.workshop_reglages where id = 1)
                    end,
    'lecons_intro', (select coalesce(json_agg(json_build_object('id', id, 'title', title)), '[]'::json) from intro)
  );
$$;

revoke all on function public.mon_guide() from public, anon;
grant execute on function public.mon_guide() to authenticated;

-- Vérification.
select count(*) filter (where guide_fait_at is null) as guides_a_faire,
       (select count(*) from public.preuves)         as captures_deposees
  from public.members;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 26-un-module.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Un seul module ouvert avant le jour 3
--  À passer APRÈS 21-workshop-rythme.sql. Rejouable.
--
--  Rectification : l'élève reçoit un module — qui contient trois vidéos —
--  et non trois modules. Le réglage revient donc à 1.
--
--  À passer même si tu as déjà lancé « 26-trois-modules.sql » : c'est ce
--  fichier-ci qui remet la bonne valeur.
-- =====================================================================

update public.workshop_reglages
   set modules_avant_j3 = 1,
       updated_at = now()
 where id = 1;

select modules_avant_j3, jour_deblocage from public.workshop_reglages where id = 1;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 28-captures-workshop.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Une capture de l'outil par jour de workshop
--  À passer APRÈS 25-guide-preuve.sql. Rejouable.
--
--  On ne savait pas ce que les élèves faisaient réellement. Le compteur
--  de jours n'est qu'un calendrier : il avance tout seul, que l'élève
--  travaille ou non. Un élève est même parti construire une tout autre
--  application sans que personne s'en aperçoive avant qu'elle plante.
--
--  Chaque jour, l'élève dépose donc une capture de son outil. Le nom de
--  l'app en haut de l'écran suffit à voir s'il est sur le bon outil,
--  et l'écran lui-même montre où il en est.
--
--  La capture n'ouvre ni ne ferme rien : les jours continuent de se
--  débloquer à minuit. C'est un témoin, pas une barrière — un élève
--  coincé un soir ne doit pas perdre son lendemain.
-- =====================================================================

create table if not exists public.workshop_captures (
  member_id  uuid not null references public.members(id) on delete cascade,
  jour       int  not null check (jour between 0 and 7),
  file_path  text not null,
  file_name  text,
  taille     int,
  created_at timestamptz not null default now(),
  primary key (member_id, jour)
);

create index if not exists workshop_captures_jour_idx
  on public.workshop_captures (jour, created_at desc);

alter table public.workshop_captures enable row level security;

drop policy if exists "eleve depose sa capture" on public.workshop_captures;
create policy "eleve depose sa capture" on public.workshop_captures
  for all using (member_id = auth.uid())
  with check (member_id = auth.uid());

drop policy if exists "equipe lit les captures" on public.workshop_captures;
create policy "equipe lit les captures" on public.workshop_captures
  for select using (public.is_equipe(auth.uid()));

-- Les fichiers vont dans le seau « preuves », qui existe déjà et dont les
-- règles portent sur le dossier au nom de l'élève. Rien à créer.

-- ---------------------------------------------------------------------
--  Ce que la page reçoit
-- ---------------------------------------------------------------------
-- `mon_workshop` gagne une colonne : la capture du jour est-elle déjà
-- déposée. Le reste de la fonction ne change pas.

-- Ajouter une colonne au retour oblige à supprimer la fonction d'abord :
-- `create or replace` refuse de changer un type de retour.
drop function if exists public.mon_workshop();

create function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz,
  capture_faite   boolean
)
language sql stable security definer set search_path = public
as $$
  with e as (
    select public.workshop_jour(auth.uid())    as jour_max,
           public.fuseau_membre(auth.uid())    as tz,
           (select workshop_debut_at from members where id = auth.uid()) as debut,
           (select workshop_dispense  from members where id = auth.uid()) as dispense
  )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           else ((((e.debut at time zone e.tz)::date + j.jour)::timestamp) at time zone e.tz)
         end,
         exists (select 1 from workshop_captures c
                  where c.member_id = auth.uid() and c.jour = j.jour)
  from workshop_jours j, e
  order by j.jour;
$$;

revoke all on function public.mon_workshop() from public, anon;
grant execute on function public.mon_workshop() to authenticated;

-- ---------------------------------------------------------------------
--  Ce que l'équipe regarde
-- ---------------------------------------------------------------------
-- Une ligne par élève : où il en est, ce qu'il a déposé, et depuis quand
-- on n'a plus rien vu de lui.

create or replace view public.suivi_workshop as
  select m.id,
         m.first_name as prenom,
         m.email,
         m.plan_code,
         m.activated_at,
         public.workshop_jour(m.id)                       as jour,
         count(c.jour)                                    as captures,
         max(c.jour)                                      as dernier_jour_depose,
         max(c.created_at)                                as derniere_capture_at,
         public.workshop_jour(m.id) - coalesce(max(c.jour), -1) as jours_de_retard
    from public.members m
    left join public.workshop_captures c on c.member_id = m.id
   where m.role = 'member'
     and not m.workshop_dispense
   group by m.id;

grant select on public.suivi_workshop to authenticated;

-- La vue n'a pas de RLS : on la réserve à l'équipe par une règle sur la
-- table qu'elle lit. `security_invoker` fait porter les droits de
-- `members` sur celui qui interroge — un élève n'y verra que sa ligne.
alter view public.suivi_workshop set (security_invoker = on);

-- Vérification.
select count(*) as captures_deposees from public.workshop_captures;


-- ╔══════════════════════════════════════════════════════════
-- ║  C. Espace membre — 30-depart-inscription.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Le workshop part de l'inscription, pas de la première visite
--  À passer APRÈS 28-captures-workshop.sql. Rejouable.
--
--  Jusqu'ici l'horloge ne démarrait qu'à deux conditions : l'élève avait
--  terminé l'introduction, et il avait chargé une page qui appelait
--  `workshop_demarrer`. Un élève inscrit samedi qui n'ouvrait « Ton
--  outil » que le lundi restait donc au jour 0 le lundi — il attendait
--  pour rien, et le setter ne comprenait pas pourquoi.
--
--  Désormais le compte à rebours part de `activated_at` : le jour 1
--  s'ouvre au minuit suivant l'inscription, quoi que fasse l'élève.
--  `workshop_debut_at` reste là, mais ne sert plus qu'à décaler
--  volontairement un élève à la main.
-- =====================================================================

-- ---------------------------------------------------------------------
-- D'où partent ses jours
-- ---------------------------------------------------------------------
-- Une seule définition, que tout le reste appelle : la date posée à la
-- main si elle existe, sinon son inscription.

create or replace function public.workshop_depart(p_member uuid)
returns timestamptz
language sql stable security definer set search_path = public
as $$
  select coalesce(workshop_debut_at, activated_at)
    from members where id = p_member;
$$;

-- ---------------------------------------------------------------------
-- Le jour en cours, compté dans le fuseau de l'élève
-- ---------------------------------------------------------------------

create or replace function public.workshop_jour(p_member uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select case
    when p_member is null then 0
    when is_equipe(p_member) then 7
    when exists (select 1 from members where id = p_member and workshop_dispense) then 7
    else coalesce(
      (
        select least(
          7,
          greatest(
            0,
            ( (now() at time zone public.fuseau_membre(p_member))::date
            - (public.workshop_depart(p_member) at time zone public.fuseau_membre(p_member))::date )::int
          )
        )
        from members m
        where m.id = p_member
      ),
      0
    )
  end;
$$;

-- ---------------------------------------------------------------------
-- La première visite ne pose plus la date, elle relève le fuseau
-- ---------------------------------------------------------------------
-- La fonction reste : c'est elle qui apprend où vit l'élève, pour que ses
-- jours s'ouvrent à minuit chez lui et non à minuit à Paris.

create or replace function public.workshop_demarrer(p_fuseau text default null)
returns int
language plpgsql volatile security definer set search_path = public
as $$
begin
  if p_fuseau is not null and exists (select 1 from pg_timezone_names where name = p_fuseau) then
    update public.members set fuseau = p_fuseau
     where id = auth.uid()
       and (fuseau is distinct from p_fuseau);
  end if;

  return public.workshop_jour(auth.uid());
end;
$$;

revoke all on function public.workshop_demarrer(text) from public, anon;
grant execute on function public.workshop_demarrer(text) to authenticated;

-- ---------------------------------------------------------------------
-- Les heures d'ouverture suivent le même départ
-- ---------------------------------------------------------------------
-- Même fonction qu'en 28, au départ près.

create or replace function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz,
  capture_faite   boolean
)
language sql stable security definer set search_path = public
as $$
  with e as (
    select public.workshop_jour(auth.uid())    as jour_max,
           public.fuseau_membre(auth.uid())    as tz,
           public.workshop_depart(auth.uid())  as debut,
           (select workshop_dispense from members where id = auth.uid()) as dispense
  )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           else ((((e.debut at time zone e.tz)::date + j.jour)::timestamp) at time zone e.tz)
         end,
         exists (select 1 from workshop_captures c
                  where c.member_id = auth.uid() and c.jour = j.jour)
  from workshop_jours j, e
  order by j.jour;
$$;

revoke all on function public.mon_workshop() from public, anon;
grant execute on function public.mon_workshop() to authenticated;

create or replace function public.mon_etat_workshop()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'jour',           public.workshop_jour(auth.uid()),
    'jour_deblocage', (select jour_deblocage from workshop_reglages where id = 1),
    'dispense',       coalesce((select workshop_dispense from members where id = auth.uid()), false),
    'equipe',         public.is_equipe(auth.uid()),
    'intro_ok',       public.intro_terminee(auth.uid()),
    'fuseau',         public.fuseau_membre(auth.uid()),
    'ouvre_le',       case
      when public.workshop_jour(auth.uid()) >= (select jour_deblocage from workshop_reglages where id = 1) then null
      else ((((public.workshop_depart(auth.uid()) at time zone public.fuseau_membre(auth.uid()))::date
              + (select jour_deblocage from workshop_reglages where id = 1))::timestamp)
             at time zone public.fuseau_membre(auth.uid()))
    end
  );
$$;

-- ---------------------------------------------------------------------
-- Les élèves déjà en retard
-- ---------------------------------------------------------------------
-- Ceux dont l'horloge avait démarré après leur inscription récupèrent les
-- jours perdus. On ne touche pas à ceux qu'on aurait décalés en avant.

update public.members
   set workshop_debut_at = null
 where workshop_debut_at is not null
   and workshop_debut_at > activated_at;

-- Vérification : les dix derniers inscrits et leur jour.
select m.email, m.activated_at, m.workshop_debut_at, m.fuseau,
       public.workshop_jour(m.id) as jour
from public.members m
where m.role = 'member'
order by m.activated_at desc
limit 10;


-- ╔══════════════════════════════════════════════════════════
-- ║  D. Correctifs
-- ╚══════════════════════════════════════════════════════════

-- 1. Les setters ont l'onglet « Suivi des élèves » : il lit la vue
--    suivi_workshop, qui applique la RLS de members. Sans cette policy,
--    seuls les administrateurs voyaient les élèves, l'onglet restait vide
--    pour les setters.
drop policy if exists "equipe lit les membres" on public.members;
create policy "equipe lit les membres" on public.members
  for select to authenticated using (public.is_equipe(auth.uid()));

-- 2. Un élève dépose et remplace sa capture du jour, mais ne l'efface pas :
--    c'est le témoin que l'équipe consulte.
drop policy if exists "eleve depose sa capture" on public.workshop_captures;
drop policy if exists "eleve lit ses captures" on public.workshop_captures;
create policy "eleve lit ses captures" on public.workshop_captures
  for select using (member_id = auth.uid());
drop policy if exists "eleve ajoute sa capture" on public.workshop_captures;
create policy "eleve ajoute sa capture" on public.workshop_captures
  for insert with check (member_id = auth.uid());
drop policy if exists "eleve remplace sa capture" on public.workshop_captures;
create policy "eleve remplace sa capture" on public.workshop_captures
  for update using (member_id = auth.uid()) with check (member_id = auth.uid());

-- 3. Le formulaire public ne lit rien : ni la table, ni ses vues.
revoke all on public.leads from anon;
grant insert on public.leads to anon;


-- ╔══════════════════════════════════════════════════════════
-- ║  E. Workshop — 21-workshop-etapes.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Workshop : la vidéo obligatoire, et des étapes pour chaque jour
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  1. Une vidéo en tête du workshop, la même pour tous : « vidéo
--     obligatoire à regarder pour comprendre le système ». Son adresse
--     se règle dans le back-office, avec le prompt du jour 0.
--  2. Chaque jour devient : un titre (ce qu'on construit aujourd'hui),
--     autant d'étapes qu'on veut, puis le prompt. Les étapes sont une
--     liste de textes, dans l'ordre.
-- =====================================================================

alter table public.workshop_reglages
  add column if not exists video_systeme_url text;

comment on column public.workshop_reglages.video_systeme_url is
  'La vidéo obligatoire en tête du workshop (Loom, Vimeo ou YouTube).';

alter table public.workshop_jours
  add column if not exists etapes jsonb not null default '[]'::jsonb;

comment on column public.workshop_jours.etapes is
  'Les étapes du jour, dans l''ordre : un tableau de textes.';

-- `mon_workshop` gagne une colonne : les étapes, renvoyées seulement pour
-- un jour ouvert, comme le prompt.
drop function if exists public.mon_workshop();

create function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz,
  capture_faite   boolean,
  etapes          jsonb
)
language sql stable security definer set search_path = public
as $$
  with e as (
    select public.workshop_jour(auth.uid())    as jour_max,
           public.fuseau_membre(auth.uid())    as tz,
           public.workshop_depart(auth.uid())  as debut,
           (select workshop_dispense from members where id = auth.uid()) as dispense
  )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           else ((((e.debut at time zone e.tz)::date + j.jour)::timestamp) at time zone e.tz)
         end,
         exists (select 1 from workshop_captures c
                  where c.member_id = auth.uid() and c.jour = j.jour),
         case when j.jour <= e.jour_max then j.etapes end
  from workshop_jours j, e
  order by j.jour;
$$;

revoke all on function public.mon_workshop() from public, anon;
grant execute on function public.mon_workshop() to authenticated;

-- Vérification : 7 jours, et la colonne de la vidéo présente.
select (select count(*) from public.workshop_jours)                       as jours,
       (select video_systeme_url from public.workshop_reglages where id = 1) as video_systeme;


-- ╔══════════════════════════════════════════════════════════
-- ║  F. Workshop — 22-prompt-secours.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Workshop : le prompt de secours
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Un seul prompt pour les sept jours : quand quelque chose ne marche
--  plus, l'élève décrit ce qu'il voit et le colle dans Base44. Il
--  s'affiche en bonus sous les sept jours, et chaque jour y renvoie. Il
--  se modifie dans le back-office, avec le prompt du jour 0.
--  À passer APRÈS 21-workshop-etapes.sql.
-- =====================================================================

alter table public.workshop_reglages
  add column if not exists prompt_secours text;

comment on column public.workshop_reglages.prompt_secours is
  'Le prompt de secours du workshop, commun aux sept jours.';

-- Le texte fourni le 18/10. On ne l'écrit que s'il n'y en a pas encore :
-- rejouer ce fichier n'écrase pas une version modifiée depuis.
update public.workshop_reglages
   set prompt_secours = $secours$Quelque chose ne marche plus dans mon premier site : [décris ce que tu vois, sur quelle page, et ce que tu as fait juste avant].
Si le texte entre crochets n'a pas été remplacé, demande-moi d'abord ce qui ne marche pas, sans rien modifier.

Corrige uniquement ce problème. Ne modifie aucune autre page, ne change rien au design, ne supprime aucune donnée.

Avant de terminer, vérifie que le problème a disparu, que tout ce qui marchait avant marche toujours, et que mes données sont toujours là après un rechargement complet de la page, en mode clair comme en mode sombre.$secours$,
       updated_at = now()
 where id = 1
   and prompt_secours is null;

-- Vérification.
select length(prompt_secours) as caracteres_prompt_secours
  from public.workshop_reglages where id = 1;


-- ╔══════════════════════════════════════════════════════════
-- ║  G. Espace membre — 23-modules-jour-3.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les modules : deux ouverts à l'arrivée, tout le reste au jour 3
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Règle reprise de Mexed (19/10) :
--  - dès son arrivée, l'élève a ses deux premiers modules ouverts ;
--  - au jour 3 du workshop, tous les modules de sa formule s'ouvrent
--    d'un coup (mensuel : les modules 1 à 3 ; annuel : tous).
--
--  On retire donc la progression qui imposait de terminer un module pour
--  ouvrir le suivant : avec elle, le module 2 restait fermé tant que le 1
--  n'était pas fini, et le jour 3 n'ouvrait rien d'un coup.
--  Le nombre de modules ouverts avant le jour 3 et le jour de déblocage
--  restent réglables dans le back-office (Workshop 7 jours → Le rythme).
-- =====================================================================

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Première porte : les vidéos d'introduction, s'il y en a.
        intro_terminee(p_member)
        -- La formule de l'élève contient ce module.
        and has_module(p_member, p_module)
        -- Le palier du workshop : avant le jour de déblocage, seuls les
        -- premiers modules. Un élève dispensé a workshop_jour = 7.
        and (
          workshop_jour(p_member) >= (select jour_deblocage from workshop_reglages where id = 1)
          or (
            select count(*) from modules m2
            where not m2.is_intro
              and m2.position <= (select position from modules where id = p_module)
          ) <= (select modules_avant_j3 from workshop_reglages where id = 1)
        )
      );
$$;

-- L'état du workshop dit aussi combien de modules sont ouverts avant le
-- déblocage : l'espace membre l'annonce à l'élève.
create or replace function public.mon_etat_workshop()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'jour',           public.workshop_jour(auth.uid()),
    'jour_deblocage', (select jour_deblocage from workshop_reglages where id = 1),
    'dispense',       coalesce((select workshop_dispense from members where id = auth.uid()), false),
    'equipe',         public.is_equipe(auth.uid()),
    'intro_ok',       public.intro_terminee(auth.uid()),
    'modules_avant',  (select modules_avant_j3 from workshop_reglages where id = 1),
    'fuseau',         public.fuseau_membre(auth.uid()),
    'ouvre_le',       case
      when public.workshop_jour(auth.uid()) >= (select jour_deblocage from workshop_reglages where id = 1) then null
      else ((((public.workshop_depart(auth.uid()) at time zone public.fuseau_membre(auth.uid()))::date
              + (select jour_deblocage from workshop_reglages where id = 1))::timestamp)
             at time zone public.fuseau_membre(auth.uid()))
    end
  );
$$;

-- Vérification : le réglage en place.
select modules_avant_j3 as modules_ouverts_a_l_arrivee, jour_deblocage
  from public.workshop_reglages where id = 1;


-- ╔══════════════════════════════════════════════════════════
-- ║  H. Espace membre — 24-modules-bonus.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les modules vidéo bonus (TikTok Shop, etc.)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 23-modules-jour-3.sql.
--
--  Un module bonus s'affiche à part, sous « Ton programme », dans une
--  catégorie « Modules vidéo bonus ». Il se crée comme un module normal
--  (un titre, puis ses leçons vidéo) depuis le back-office → Contenu.
--
--  Accès : comme le reste du programme, selon la formule de l'élève
--  (le back-office coche les deux formules à la création), et ouvert
--  au jour 3 du workshop. Il ne compte jamais parmi les modules ouverts
--  dès l'arrivée, et pas dans l'avancement du programme.
-- =====================================================================

alter table public.modules
  add column if not exists is_bonus boolean not null default false;

comment on column public.modules.is_bonus is
  'Module vidéo bonus : affiché à part, sous le programme.';

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Première porte : les vidéos d'introduction, s'il y en a.
        intro_terminee(p_member)
        -- La formule de l'élève contient ce module.
        and has_module(p_member, p_module)
        -- Le palier du workshop : avant le jour de déblocage, seuls les
        -- premiers modules du programme. Un bonus attend toujours ce jour.
        and (
          workshop_jour(p_member) >= (select jour_deblocage from workshop_reglages where id = 1)
          or (
            not (select is_bonus from modules where id = p_module)
            and (
              select count(*) from modules m2
              where not m2.is_intro and not m2.is_bonus
                and m2.position <= (select position from modules where id = p_module)
            ) <= (select modules_avant_j3 from workshop_reglages where id = 1)
          )
        )
      );
$$;

drop function if exists public.my_modules();

create function public.my_modules()
returns table (
  id          bigint,
  "position"  int,
  title       text,
  description text,
  is_intro    boolean,
  lesson_count int,
  done_count   int,
  completion   numeric,
  unlocked     boolean,
  is_bonus     boolean
)
language sql stable security definer set search_path = public
as $$
  select m.id, m.position, m.title, m.description, m.is_intro,
         (select count(*)::int from lessons l where l.module_id = m.id),
         (select count(*)::int from lessons l
            join lesson_progress p on p.lesson_id = l.id and p.member_id = auth.uid()
           where l.module_id = m.id),
         module_completion(auth.uid(), m.id),
         is_module_unlocked(auth.uid(), m.id),
         m.is_bonus
  from modules m
  where has_module(auth.uid(), m.id) or is_equipe(auth.uid())
  order by m.is_intro desc, m.is_bonus, m.position;
$$;

revoke all on function public.my_modules() from public, anon;
grant execute on function public.my_modules() to authenticated;

-- Vérification : la colonne est là, aucun bonus pour l'instant.
select count(*) filter (where is_bonus) as modules_bonus, count(*) as modules
  from public.modules;


-- ╔══════════════════════════════════════════════════════════
-- ║  I. Espace membre — 25-bonus-des-l-arrivee.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Les vidéos bonus, ouvertes dès l'arrivée
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 24-modules-bonus.sql.
--
--  Décision du 19/10 : le bonus n'est que du plus, il n'a pas à attendre
--  le jour 3. Il reste réservé aux formules qui le contiennent (les deux,
--  par défaut). Le jour 3 continue d'ouvrir le reste du programme.
-- =====================================================================

create or replace function public.is_module_unlocked(p_member uuid, p_module bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select is_equipe(p_member)
      -- Les introductions restent ouvertes : c'est par elles qu'on entre.
      or exists (select 1 from modules where id = p_module and is_intro)
      or (
        -- Première porte : les vidéos d'introduction, s'il y en a.
        intro_terminee(p_member)
        -- La formule de l'élève contient ce module.
        and has_module(p_member, p_module)
        and (
          -- Le bonus : ouvert dès l'arrivée.
          (select is_bonus from modules where id = p_module)
          -- Le programme : tout au jour de déblocage, et avant cela
          -- seulement les premiers modules.
          or workshop_jour(p_member) >= (select jour_deblocage from workshop_reglages where id = 1)
          or (
            select count(*) from modules m2
            where not m2.is_intro and not m2.is_bonus
              and m2.position <= (select position from modules where id = p_module)
          ) <= (select modules_avant_j3 from workshop_reglages where id = 1)
        )
      );
$$;

-- Vérification : les modules bonus existants.
select id, title, is_bonus from public.modules where is_bonus;


-- =====================================================================
--  Le parcours automatique (numéros africains)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 25-bonus-des-l-arrivee.sql.
--
--  Un numéro africain qui confirme avoir le budget ne passe plus par un
--  setter : il suit la page « Active ton accès », prend son abonnement
--  Base44 avec notre lien, puis dépose sa facture. L'équipe la vérifie
--  dans le CRM et lui ouvre son espace membre.
--
--  Rien ne change pour les autres leads : ce fichier ajoute, il ne
--  modifie aucun comportement existant.
-- =====================================================================

-- 1. Une troisième liste de leads, que les setters ne voient pas dans
--    leur liste du jour.
alter table public.leads drop constraint if exists leads_vivier_check;
alter table public.leads add constraint leads_vivier_check
  check (vivier in ('formulaire', 'iclosed', 'auto'));

-- 2. Ce que le parcours enregistre sur le lead.
alter table public.leads
  add column if not exists auto_jeton      uuid,          -- secret du navigateur du lead
  add column if not exists facture_path    text,          -- chemin dans le seau « factures-auto »
  add column if not exists facture_nom     text,
  add column if not exists facture_at      timestamptz,
  add column if not exists acces_valide_at timestamptz,   -- facture vérifiée, accès ouvert
  add column if not exists invite_token    uuid;          -- l'invitation créée pour lui

comment on column public.leads.auto_jeton is
  'Parcours automatique : secret connu du seul navigateur du lead. Il autorise le dépôt de sa facture.';

-- 3. Le dépôt de la facture. Le formulaire public n'a le droit que
--    d'insérer un lead : la facture passe par cette fonction, qui vérifie
--    le secret avant d'écrire.
create or replace function public.deposer_facture_auto(
  p_lead uuid, p_jeton uuid, p_chemin text, p_nom text
)
returns boolean
language plpgsql volatile security definer set search_path = public
as $$
begin
  update leads
     set facture_path = p_chemin,
         facture_nom  = left(p_nom, 200),
         facture_at   = now()
   where id = p_lead
     and vivier = 'auto'
     and auto_jeton = p_jeton
     and p_chemin like p_lead::text || '/%';
  return found;
end;
$$;

revoke all on function public.deposer_facture_auto(uuid, uuid, text, text) from public;
grant execute on function public.deposer_facture_auto(uuid, uuid, text, text) to anon, authenticated;

-- Le stockage ne lit pas la table : cette fonction lui dit si le dossier
-- correspond bien à un lead du parcours.
create or replace function public.lead_auto_existe(p_dossier text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from leads
     where id::text = p_dossier and vivier = 'auto' and acces_valide_at is null
  );
$$;

revoke all on function public.lead_auto_existe(text) from public;
grant execute on function public.lead_auto_existe(text) to anon, authenticated;

-- 4. Le seau des factures : privé. Le lead y dépose, seule l'équipe lit.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('factures-auto', 'factures-auto', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update
  set public = false, file_size_limit = 10485760,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "lead depose sa facture auto" on storage.objects;
create policy "lead depose sa facture auto" on storage.objects
  for insert to anon, authenticated with check (
    bucket_id = 'factures-auto'
    and public.lead_auto_existe((storage.foldername(name))[1])
  );

drop policy if exists "equipe lit les factures auto" on storage.objects;
create policy "equipe lit les factures auto" on storage.objects
  for select to authenticated using (
    bucket_id = 'factures-auto' and public.is_staff()
  );

-- Vérification.
select (select count(*) from leads where vivier = 'auto') as leads_automatiques,
       (select public from storage.buckets where id = 'factures-auto') as seau_public;


-- =====================================================================
--  Disponibilités des setters, et présence dans le CRM
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 26-parcours-automatique.sql.
--
--  1. Les dispos : chaque setter donne ses créneaux de la semaine
--     suivante avant le dimanche 20 h, à son heure à lui (les setters
--     ne sont pas tous en France). Ce qui bouge après la limite est
--     marqué « tardif », et un créneau retiré tard reste visible, barré.
--  2. La présence : dernière action, signal « CRM ouvert », et
--     l'historique des passages en inactif. Les administrateurs seuls
--     peuvent lire ces tables ; un setter ne fait qu'envoyer ses signaux,
--     par des fonctions qui ne renvoient rien.
--
--  Ce fichier ajoute, il ne modifie aucun comportement existant.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Les réglages du CRM : la limite des dispos
-- ---------------------------------------------------------------------
create table if not exists public.crm_reglages (
  id                  int primary key default 1 check (id = 1),
  -- Le jour de la limite, dans la semaine qui précède : 1 = lundi … 7 = dimanche.
  dispos_jour_limite  int  not null default 7 check (dispos_jour_limite between 1 and 7),
  dispos_heure_limite time not null default '20:00'
);
insert into public.crm_reglages (id) values (1) on conflict (id) do nothing;

alter table public.crm_reglages enable row level security;

drop policy if exists "equipe lit les reglages" on public.crm_reglages;
create policy "equipe lit les reglages"
  on public.crm_reglages for select to authenticated
  using (public.is_staff());

drop policy if exists "admin modifie les reglages" on public.crm_reglages;
create policy "admin modifie les reglages"
  on public.crm_reglages for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Un fuseau inconnu ne doit rien casser : on retombe sur Paris.
create or replace function public.fuseau_valide(p_fuseau text)
returns text
language sql stable set search_path = public
as $$
  select coalesce(
    (select name from pg_timezone_names where name = p_fuseau limit 1),
    'Europe/Paris');
$$;

-- La limite d'une semaine (son lundi), à l'heure du fuseau donné.
-- Dimanche 20 h par défaut : la veille du lundi, à 20 h.
create or replace function public.limite_dispos(p_semaine date, p_fuseau text)
returns timestamptz
language sql stable set search_path = public
as $$
  select ((p_semaine - 8 + r.dispos_jour_limite)::timestamp + r.dispos_heure_limite)
           at time zone public.fuseau_valide(p_fuseau)
  from public.crm_reglages r where r.id = 1;
$$;

-- ---------------------------------------------------------------------
-- 1. Les dispos
-- ---------------------------------------------------------------------
create table if not exists public.dispos (
  id          bigserial primary key,
  setter_id   uuid not null references public.staff(user_id) on delete cascade,
  semaine     date not null,                 -- le lundi de la semaine
  jour        date not null,                 -- le jour, à l'heure du setter
  debut       time not null,
  fin         time not null,
  fuseau      text not null default 'Europe/Paris',
  debut_at    timestamptz not null,          -- le même créneau, en heure absolue
  fin_at      timestamptz not null,
  tardif      boolean not null default false, -- touché après la limite
  ancien      jsonb,                          -- ce qui était prévu avant le changement tardif
  supprime_at timestamptz,                    -- retiré après la limite : gardé, barré
  created_at  timestamptz not null default now(),
  modifie_at  timestamptz not null default now(),
  check (fin > debut)
);
create index if not exists dispos_semaine_idx on public.dispos (semaine, setter_id);

-- Une semaine où le setter n'est pas disponible du tout : il le dit, et
-- le rappel s'éteint.
create table if not exists public.dispos_absences (
  setter_id  uuid not null references public.staff(user_id) on delete cascade,
  semaine    date not null,
  tardif     boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (setter_id, semaine)
);

alter table public.dispos          enable row level security;
alter table public.dispos_absences enable row level security;

-- Lire : le setter ses propres lignes, l'administrateur toutes.
-- Écrire : seulement par les fonctions ci-dessous, qui vérifient tout.
drop policy if exists "dispos lues par leur setter ou un admin" on public.dispos;
create policy "dispos lues par leur setter ou un admin"
  on public.dispos for select to authenticated
  using (setter_id = auth.uid() or public.is_admin());

drop policy if exists "absences lues par leur setter ou un admin" on public.dispos_absences;
create policy "absences lues par leur setter ou un admin"
  on public.dispos_absences for select to authenticated
  using (setter_id = auth.uid() or public.is_admin());

revoke insert, update, delete on public.dispos, public.dispos_absences from anon, authenticated;

-- Ajouter un créneau (p_id null) ou en modifier un.
create or replace function public.enregistrer_dispo(
  p_id bigint, p_jour date, p_debut time, p_fin time, p_fuseau text
)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare
  tz       text := public.fuseau_valide(p_fuseau);
  sem      date := date_trunc('week', p_jour)::date;
  auj      date := (now() at time zone tz)::date;
  en_retard boolean;
  ligne    public.dispos;
  nouvel   bigint;
begin
  if not public.is_staff() then raise exception 'Réservé à l''équipe'; end if;
  if p_fin <= p_debut then raise exception 'La fin doit venir après le début'; end if;
  if p_jour < auj then raise exception 'Ce jour est déjà passé'; end if;
  if sem > date_trunc('week', auj)::date + 21 then
    raise exception 'On remplit au plus trois semaines à l''avance';
  end if;
  if exists (select 1 from dispos d
              where d.setter_id = auth.uid() and d.jour = p_jour and d.supprime_at is null
                and d.id is distinct from p_id
                and d.debut < p_fin and p_debut < d.fin) then
    raise exception 'Ce créneau chevauche un autre créneau du même jour';
  end if;

  en_retard := now() > public.limite_dispos(sem, tz);

  if p_id is null then
    insert into dispos (setter_id, semaine, jour, debut, fin, fuseau, debut_at, fin_at, tardif)
    values (auth.uid(), sem, p_jour, p_debut, p_fin, tz,
            (p_jour + p_debut) at time zone tz, (p_jour + p_fin) at time zone tz, en_retard)
    returning id into nouvel;
    delete from dispos_absences where setter_id = auth.uid() and semaine = sem;
    return nouvel;
  end if;

  select * into ligne from dispos
   where id = p_id and setter_id = auth.uid() and supprime_at is null
   for update;
  if not found then raise exception 'Créneau introuvable'; end if;
  if ligne.jour < auj then raise exception 'Ce jour est déjà passé'; end if;

  update dispos set
    semaine    = sem,
    jour       = p_jour,
    debut      = p_debut,
    fin        = p_fin,
    fuseau     = tz,
    debut_at   = (p_jour + p_debut) at time zone tz,
    fin_at     = (p_jour + p_fin) at time zone tz,
    tardif     = ligne.tardif or en_retard,
    -- On garde ce qui était prévu à la limite : le premier changement
    -- tardif le fige, les suivants ne l'écrasent pas.
    ancien     = case when en_retard and not ligne.tardif and ligne.ancien is null
                      then jsonb_build_object('jour', ligne.jour, 'debut', ligne.debut, 'fin', ligne.fin,
                                              'debut_at', ligne.debut_at, 'fin_at', ligne.fin_at)
                      else ligne.ancien end,
    modifie_at = now()
  where id = p_id;
  return p_id;
end;
$$;

-- Retirer un créneau. Avant la limite, il disparaît ; après, il reste
-- barré pour que l'administrateur voie le changement.
create or replace function public.supprimer_dispo(p_id bigint)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare ligne public.dispos;
begin
  select * into ligne from dispos
   where id = p_id and setter_id = auth.uid() and supprime_at is null
   for update;
  if not found then raise exception 'Créneau introuvable'; end if;
  if ligne.jour < (now() at time zone ligne.fuseau)::date then
    raise exception 'Ce jour est déjà passé';
  end if;
  if now() > public.limite_dispos(ligne.semaine, ligne.fuseau) then
    update dispos set supprime_at = now(), tardif = true, modifie_at = now() where id = p_id;
  else
    delete from dispos where id = p_id;
  end if;
end;
$$;

-- « Pas disponible cette semaine » : coché, le rappel s'éteint.
create or replace function public.declarer_absence(p_semaine date, p_absent boolean, p_fuseau text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare sem date := date_trunc('week', p_semaine)::date;
begin
  if not public.is_staff() then raise exception 'Réservé à l''équipe'; end if;
  if p_absent then
    insert into dispos_absences (setter_id, semaine, tardif)
    values (auth.uid(), sem, now() > public.limite_dispos(sem, p_fuseau))
    on conflict (setter_id, semaine) do nothing;
  else
    delete from dispos_absences where setter_id = auth.uid() and semaine = sem;
  end if;
end;
$$;

revoke all on function public.enregistrer_dispo(bigint, date, time, time, text) from public, anon;
revoke all on function public.supprimer_dispo(bigint)                         from public, anon;
revoke all on function public.declarer_absence(date, boolean, text)           from public, anon;
grant execute on function public.enregistrer_dispo(bigint, date, time, time, text) to authenticated;
grant execute on function public.supprimer_dispo(bigint)                         to authenticated;
grant execute on function public.declarer_absence(date, boolean, text)           to authenticated;

-- ---------------------------------------------------------------------
-- 2. La présence
-- ---------------------------------------------------------------------
create table if not exists public.presence (
  user_id           uuid primary key references public.staff(user_id) on delete cascade,
  last_activity_at  timestamptz,  -- dernière action : changement d'onglet, clic sur un bouton
  last_heartbeat_at timestamptz,  -- dernier signal « CRM ouvert », toutes les 60 s
  ouvert_depuis     timestamptz,  -- début de la session en cours
  connecte          boolean not null default false,
  fuseau            text
);

create table if not exists public.inactivites (
  id      bigserial primary key,
  user_id uuid not null references public.staff(user_id) on delete cascade,
  debut   timestamptz not null,   -- le moment où le setter est passé « inactif »
  fin     timestamptz             -- vide tant que ça dure
);
create index if not exists inactivites_jour_idx on public.inactivites (debut, user_id);

alter table public.presence    enable row level security;
alter table public.inactivites enable row level security;

-- Administrateurs seulement. Aucune policy d'écriture : un setter ne
-- lit ni n'écrit ces tables, il passe par les fonctions qui suivent.
drop policy if exists "admin lit la presence" on public.presence;
create policy "admin lit la presence"
  on public.presence for select to authenticated
  using (public.is_admin());

drop policy if exists "admin lit les inactivites" on public.inactivites;
create policy "admin lit les inactivites"
  on public.inactivites for select to authenticated
  using (public.is_admin());

revoke all on public.presence, public.inactivites from anon;
revoke insert, update, delete on public.presence, public.inactivites from authenticated;

-- Le cœur commun aux trois signaux. Seuls les setters sont suivis.
--   p_type : 'action', 'battement' ou 'sortie'.
create or replace function public.presence_signal(p_type text, p_fuseau text default null)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  maintenant timestamptz := now();
  p    public.presence;
  reprise boolean;
begin
  if not exists (select 1 from staff where user_id = uid and actif and role = 'setter') then
    return;
  end if;

  insert into presence (user_id) values (uid) on conflict (user_id) do nothing;
  select * into p from presence where user_id = uid for update;

  -- Le CRM avait été fermé (plus de signal depuis 2 minutes) ou le setter
  -- s'était déconnecté : l'inactivité en cours s'est arrêtée au dernier
  -- signal, et une nouvelle session commence.
  reprise := not p.connecte or p.last_heartbeat_at is null
             or p.last_heartbeat_at < maintenant - interval '2 minutes';
  if reprise then
    update inactivites set fin = coalesce(p.last_heartbeat_at, maintenant)
     where user_id = uid and fin is null;
  end if;

  if p_type = 'sortie' then
    update inactivites set fin = maintenant where user_id = uid and fin is null;
    update presence set connecte = false where user_id = uid;
    return;
  end if;

  if p_type = 'action' then
    update inactivites set fin = maintenant where user_id = uid and fin is null;
    update presence set
      last_activity_at  = maintenant,
      last_heartbeat_at = maintenant,
      ouvert_depuis     = case when reprise then maintenant else ouvert_depuis end,
      connecte          = true,
      fuseau            = case when p_fuseau is null then fuseau
                               else public.fuseau_valide(p_fuseau) end
    where user_id = uid;
    return;
  end if;

  -- Le battement : le CRM est ouvert. S'il n'y a eu aucune action depuis
  -- 60 minutes, le setter passe inactif, à partir du moment exact où les
  -- 60 minutes se sont écoulées (ou du début de la session, s'il a
  -- rouvert le CRM sans rien toucher).
  update presence set
    last_heartbeat_at = maintenant,
    ouvert_depuis     = case when reprise then maintenant else ouvert_depuis end,
    connecte          = true
  where user_id = uid
  returning * into p;

  if p.last_activity_at is not null
     and p.last_activity_at <= maintenant - interval '60 minutes'
     and not exists (select 1 from inactivites where user_id = uid and fin is null) then
    insert into inactivites (user_id, debut)
    values (uid, greatest(p.last_activity_at + interval '60 minutes', p.ouvert_depuis));
  end if;
end;
$$;

revoke all on function public.presence_signal(text, text) from public, anon;
grant execute on function public.presence_signal(text, text) to authenticated;

-- Vérification : les quatre tables, et les réglages par défaut.
select (select count(*) from public.dispos)      as dispos,
       (select count(*) from public.presence)    as presences,
       (select count(*) from public.inactivites) as inactivites,
       r.dispos_jour_limite, r.dispos_heure_limite
from public.crm_reglages r where r.id = 1;


-- =====================================================================
--  Dispos : la règle de la limite ne compte qu'à partir d'une semaine
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 27-dispos-presence.sql.
--
--  On lance les dispos en pleine semaine : les setters remplissent la
--  semaine en cours sans limite, et rien n'y est marqué « tardif ». La
--  limite du dimanche 20 h s'applique à partir de la semaine du lundi
--  26 octobre 2026 (limite : dimanche 25 à 20 h).
-- =====================================================================

alter table public.crm_reglages
  add column if not exists dispos_depart date not null default '2026-10-26';

comment on column public.crm_reglages.dispos_depart is
  'Le lundi de la première semaine soumise à la limite. Avant, pas de limite ni de changement tardif.';

-- Une semaine d'avant le départ n'a pas de limite : `now() > infinity`
-- n'est jamais vrai, donc rien n'y devient tardif.
create or replace function public.limite_dispos(p_semaine date, p_fuseau text)
returns timestamptz
language sql stable set search_path = public
as $$
  select case
           when p_semaine < r.dispos_depart then 'infinity'::timestamptz
           else ((p_semaine - 8 + r.dispos_jour_limite)::timestamp + r.dispos_heure_limite)
                  at time zone public.fuseau_valide(p_fuseau)
         end
  from public.crm_reglages r where r.id = 1;
$$;

-- Vérification : cette semaine sans limite, la suivante au dimanche 25 à 20 h (Paris).
select public.limite_dispos('2026-10-19', 'Europe/Paris') as semaine_du_19,
       public.limite_dispos('2026-10-26', 'Europe/Paris') as semaine_du_26;


-- ╔══════════════════════════════════════════════════════════
-- ║  Y. Sirius — 01-formulaire-base44-seulement.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Sirius — le formulaire public ne dépose que chez Base44
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Sans ça, quelqu'un qui appelle l'API à la main avec la clé anon pourrait
--  glisser un lead dans l'équipe Skool, ou dans le vivier du
--  parcours automatique (qui n'existe pas sur la page Sirius).
-- =====================================================================

drop policy if exists "public peut deposer un lead" on public.leads;
create policy "public peut deposer un lead"
  on public.leads for insert
  to anon
  with check (
    status = 'nouveau'
    and setter_id is null
    and called_at is null
    and notes is null
    and dials = 0
    and cash_collecte = 0
    and equipe = 'starter'        -- Base44, la seule équipe qui travaille le formulaire
    and vivier = 'formulaire'
    and auto_jeton is null
  );


-- ╔══════════════════════════════════════════════════════════
-- ║  Z. Sirius — 02-reservations-skool.sql
-- ╚══════════════════════════════════════════════════════════
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


-- ╔══════════════════════════════════════════════════════════
-- ║  Z2. Sirius — 03-lien-equipe-skool.sql
-- ╚══════════════════════════════════════════════════════════
-- =====================================================================
--  Sirius — un seul lien de réservation pour toute l'équipe Skool
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 02-reservations-skool.sql (il fait aussi partie
--  d'INSTALLATION.sql, en dernier).
--
--  Le lien de l'équipe (<page de vente>/rdv, sans code) montre tous les
--  créneaux où au moins un setter Skool est libre. À la réservation,
--  l'appel va au setter libre à cette heure-là ; s'ils sont plusieurs,
--  à celui qui a le moins d'appels réservés ce jour-là, puis le moins
--  d'appels à venir, puis au hasard.
--
--  Les liens personnels (/rdv/<code>) marchent toujours : même fonctions,
--  avec un code.
--
--  Seuls les setters comptent (pas les administrateurs, qui ont accès à
--  l'équipe Skool pour la voir, pas pour prendre des appels).
-- =====================================================================

-- Les setters de l'équipe Skool, actifs.
create or replace function public.rdv_setters_equipe()
returns setof public.staff
language sql stable security definer set search_path = public
as $$
  select s.* from public.staff s
  where s.actif
    and s.role = 'setter'
    and 'skool' = any(coalesce(s.equipes, array[s.equipe]));
$$;

revoke all on function public.rdv_setters_equipe() from public, anon, authenticated;

-- Ce que voit le public. Sans code : les créneaux de toute l'équipe,
-- sans prénom (on ne sait pas encore qui appellera).
create or replace function public.rdv_calendrier(p_code text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  s public.staff;
  r public.crm_reglages;
begin
  select * into r from public.crm_reglages where id = 1;

  if coalesce(btrim(p_code), '') = '' then
    return jsonb_build_object(
      'prenom',   null,
      'duree',    r.rdv_duree_min,
      'creneaux', coalesce((
        select jsonb_agg(d order by d) from (
          select distinct c.debut as d
          from public.rdv_setters_equipe() e,
               lateral public.rdv_creneaux_setter(e.user_id) c
        ) x), '[]'::jsonb)
    );
  end if;

  s := public.rdv_setter(p_code);
  if s.user_id is null then return null; end if;
  return jsonb_build_object(
    'prenom',   s.first_name,
    'duree',    r.rdv_duree_min,
    'creneaux', coalesce((select jsonb_agg(c.debut order by c.debut)
                          from public.rdv_creneaux_setter(s.user_id) c), '[]'::jsonb)
  );
end;
$$;

-- Réserver. Sans code : le setter est choisi ici, au moment de réserver.
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
  s     public.staff;
  r     public.crm_reglages;
  qui   uuid;
  tel   text := regexp_replace(coalesce(p_telephone, ''), '[^0-9+]', '', 'g');
  jour0 timestamptz := date_trunc('day', p_debut);
begin
  -- Une réservation à la fois pour toute l'équipe : la vérification du
  -- créneau, le choix du setter et l'insertion ne se croisent jamais.
  perform pg_advisory_xact_lock(hashtext('rdv:skool'));

  if coalesce(btrim(p_code), '') <> '' then
    s := public.rdv_setter(p_code);
    if s.user_id is null then
      raise exception 'Ce lien de réservation n''existe plus.' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.rdv_creneaux_setter(s.user_id) c where c.debut = p_debut) then
      qui := s.user_id;
    end if;
  else
    select e.user_id into qui
    from public.rdv_setters_equipe() e
    where exists (select 1 from public.rdv_creneaux_setter(e.user_id) c where c.debut = p_debut)
    order by
      (select count(*) from public.leads l
        where l.setter_id = e.user_id and l.rdv_annule_at is null
          and l.rdv_at >= jour0 and l.rdv_at < jour0 + interval '1 day'),
      (select count(*) from public.leads l
        where l.setter_id = e.user_id and l.rdv_annule_at is null and l.rdv_at > now()),
      random()
    limit 1;
  end if;

  if qui is null then
    raise exception 'Ce créneau vient d''être pris. Choisis-en un autre.' using errcode = 'P0001';
  end if;

  -- Un même numéro n'a qu'un appel à venir dans l'équipe.
  if exists (select 1 from public.leads
             where equipe = 'skool' and phone = tel
               and rdv_at > now() and rdv_annule_at is null) then
    raise exception 'Tu as déjà un appel réservé. On te contacte à l''heure prévue.'
      using errcode = 'P0001';
  end if;

  select * into r from public.crm_reglages where id = 1;
  select * into s from public.staff where user_id = qui;

  insert into public.leads (
    first_name, last_name, email, phone, page_url, source,
    equipe, vivier, status, setter_id,
    rdv_at, rdv_fin_at, rdv_reserve_at
  ) values (
    btrim(p_prenom), btrim(p_nom), lower(btrim(p_email)), tel,
    left(p_page_url, 300), left(p_source, 300),
    'skool', 'formulaire', 'nouveau', qui,
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

-- Vérification : les setters de l'équipe, et le nombre de créneaux libres de chacun.
select e.first_name, (select count(*) from public.rdv_creneaux_setter(e.user_id)) as creneaux_libres
from public.rdv_setters_equipe() e
order by e.first_name;

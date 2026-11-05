-- =====================================================================
--  Sirius — le suivi par source : visites, formulaires, paiements, ventes
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  La page compte chaque visiteur une fois par jour et par source, avec un
--  identifiant aléatoire gardé dans son navigateur : ni nom, ni adresse IP.
--  stats_sources() rassemble tout pour l'onglet Sources du CRM, réservé aux
--  administrateurs. Mêmes règles que rapport_pages : jours en heure de
--  Paris, même calcul de la source, même définition d'une vente.
-- =====================================================================

create table if not exists public.visites (
  jour     date not null,
  origine  text not null,
  visiteur uuid not null,
  offre    text not null default 'sirius',
  vues     int  not null default 1,
  primary key (jour, origine, visiteur, offre)
);

alter table public.visites enable row level security;
revoke all on public.visites from anon, authenticated;

create index if not exists visites_jour_idx on public.visites (jour, offre);

create or replace function public.visite_compter(p_visiteur uuid, p_origine text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_origine text := left(lower(regexp_replace(coalesce(p_origine, ''), '[^A-Za-z0-9_-]', '', 'g')), 60);
begin
  if p_visiteur is null then return; end if;
  insert into visites (jour, origine, visiteur)
  values ((now() at time zone 'Europe/Paris')::date, coalesce(nullif(v_origine, ''), 'direct'), p_visiteur)
  on conflict (jour, origine, visiteur, offre) do update set vues = visites.vues + 1;
end;
$$;

revoke all on function public.visite_compter(uuid, text) from public;
grant execute on function public.visite_compter(uuid, text) to anon, authenticated;

create or replace function public.stats_sources(p_du date, p_au date, p_offre text default 'sirius')
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  debut timestamptz := p_du::timestamp at time zone 'Europe/Paris';
  fin   timestamptz := (p_au + 1)::timestamp at time zone 'Europe/Paris';
  resultat json;
begin
  if not public.is_admin() then
    raise exception 'Réservé aux administrateurs' using errcode = '42501';
  end if;
  if p_du is null or p_au is null or p_au < p_du or p_au - p_du > 400 then
    raise exception 'Période invalide' using errcode = '22023';
  end if;

  with
  perimetre as (
    select l.*,
      lower(coalesce(
        nullif(l.utm_source, ''),
        substring(l.page_url from '[?&]utm_source=([^&]+)'),
        nullif(l.ref, ''),
        substring(l.page_url from '[?&]ref=([^&]+)'),
        case when l.source !~ '^https?://' then null
             when l.source ~* 'tiktok' then 'tiktok'
             when l.source ~* 'instagram' then 'instagram'
             when l.source ~* 'snapchat' then 'snapchat'
             when l.source ~* 'facebook|fb\.' then 'facebook'
             when l.source ~* 'youtube|youtu\.be' then 'youtube'
             else regexp_replace(l.source, '^https?://(www\.)?([^/]+).*$', '\2') end,
        'direct'
      )) as origine
    from public.leads l
    where l.equipe = 'starter' and l.offre = p_offre and l.vivier in ('formulaire', 'optin')
  ),
  forms as (
    select origine, count(*) as formulaires,
      count(*) filter (where dials > 0 or status::text <> 'nouveau') as appeles
    from perimetre where created_at >= debut and created_at < fin
    group by origine
  ),
  paie as (
    select coalesce(p.origine, 'non rattaché') as origine, count(*) as payes, sum(w.montant) as encaisse
    from public.whop_paiements w
    left join perimetre p on p.id = w.lead_id
    where w.statut = 'paid' and w.recu_at >= debut and w.recu_at < fin
    group by 1
  ),
  vent as (
    select origine, count(*) as ventes, sum(cash_collecte) as cash
    from perimetre
    where status::text in ('monthly', 'yearly', 'yearly_builder')
      and closed_at is not null and closed_at >= debut and closed_at < fin
    group by origine
  ),
  vis as (
    select origine, count(distinct visiteur) as visiteurs, sum(vues) as vues
    from public.visites
    where jour >= p_du and jour <= p_au and offre = p_offre
    group by origine
  ),
  noms as (
    select origine from forms union select origine from paie
    union select origine from vent union select origine from vis
  ),
  lignes as (
    select n.origine,
      coalesce(v.visiteurs, 0)   as visiteurs,
      coalesce(v.vues, 0)        as vues,
      coalesce(f.formulaires, 0) as formulaires,
      coalesce(p.payes, 0)       as payes,
      coalesce(p.encaisse, 0)    as encaisse,
      coalesce(f.appeles, 0)     as appeles,
      coalesce(s.ventes, 0)      as ventes,
      coalesce(s.cash, 0)        as cash
    from noms n
    left join vis   v on v.origine = n.origine
    left join forms f on f.origine = n.origine
    left join paie  p on p.origine = n.origine
    left join vent  s on s.origine = n.origine
  )
  select json_build_object(
    'lignes', coalesce((select json_agg(l order by l.payes desc, l.formulaires desc, l.visiteurs desc, l.origine) from lignes l), '[]'::json),
    'total', (select json_build_object(
        'visiteurs',   (select count(distinct visiteur) from public.visites
                         where jour >= p_du and jour <= p_au and offre = p_offre),
        'vues',        coalesce(sum(vues), 0),
        'formulaires', coalesce(sum(formulaires), 0),
        'payes',       coalesce(sum(payes), 0),
        'encaisse',    coalesce(sum(encaisse), 0),
        'appeles',     coalesce(sum(appeles), 0),
        'ventes',      coalesce(sum(ventes), 0),
        'cash',        coalesce(sum(cash), 0)) from lignes),
    'visites_depuis', (select min(jour) from public.visites where offre = p_offre),
    'maj', now()
  ) into resultat;

  return resultat;
end;
$$;

revoke all on function public.stats_sources(date, date, text) from public, anon;
grant execute on function public.stats_sources(date, date, text) to authenticated;

notify pgrst, 'reload schema';

-- Vérification : la table et les deux fonctions.
select count(*) as visites from public.visites;
select proname from pg_proc where proname in ('visite_compter', 'stats_sources') order by proname;

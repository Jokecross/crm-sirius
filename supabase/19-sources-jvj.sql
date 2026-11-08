-- =====================================================================
--  Sources : la page JVJ compte ses visites, et l'onglet Sources la sépare
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--  À passer APRÈS 14-sources.sql.
--
--  1. visite_compter reçoit la page (sirius par défaut) : la page Sirius
--     continue d'appeler sans rien changer, la page JVJ envoie 'jvj'.
--  2. stats_sources range chaque paiement Whop sur sa page. Avant, en vue
--     JVJ, tous les paiements Sirius seraient tombés en « non rattaché ».
-- =====================================================================

drop function if exists public.visite_compter(uuid, text);

create or replace function public.visite_compter(p_visiteur uuid, p_origine text, p_offre text default 'sirius')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_origine text := left(lower(regexp_replace(coalesce(p_origine, ''), '[^A-Za-z0-9_-]', '', 'g')), 60);
  v_offre   text := case when p_offre in ('sirius', 'jvj') then p_offre else 'sirius' end;
begin
  if p_visiteur is null then return; end if;
  insert into visites (jour, origine, visiteur, offre)
  values ((now() at time zone 'Europe/Paris')::date, coalesce(nullif(v_origine, ''), 'direct'), p_visiteur, v_offre)
  on conflict (jour, origine, visiteur, offre) do update set vues = visites.vues + 1;
end;
$$;

revoke all on function public.visite_compter(uuid, text, text) from public;
grant execute on function public.visite_compter(uuid, text, text) to anon, authenticated;

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
    left join public.leads l on l.id = w.lead_id
    left join perimetre p on p.id = w.lead_id
    where w.statut = 'paid' and w.recu_at >= debut and w.recu_at < fin
      -- La page du paiement : celle du lead, sinon le produit Whop payé.
      and coalesce(l.offre,
            case when w.brut->>'variant_id' = 'plan_tJiO0ClEebkaO' then 'jvj' else 'sirius' end) = p_offre
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

-- Vérification : une seule visite_compter, à 3 paramètres.
select proname, pg_get_function_identity_arguments(oid) as parametres
from pg_proc where proname in ('visite_compter', 'stats_sources') order by proname;

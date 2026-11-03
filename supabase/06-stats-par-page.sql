-- =====================================================================
--  Sirius — les chiffres par page de vente
--  À coller dans Supabase (projet Sirius) → SQL Editor → New query → Run.
--  Rejouable. À passer APRÈS 05-offre-jvj.sql.
--
--  1. crm_stats sait filtrer par offre (tableau de bord du CRM).
--  2. Le rapport d'Anthony : des chiffres seuls, aucune fiche, derrière
--     une clé dont seule l'empreinte est en base.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Le tableau de bord filtre par offre
-- ---------------------------------------------------------------------
drop function if exists public.crm_stats(timestamptz, timestamptz, uuid, text, text);

create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null,
  p_vivier text        default null,
  p_equipe text        default null,
  p_offre  text        default null
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
      and (p_offre  is null or offre = p_offre)
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
      and (p_offre  is null or offre = p_offre)
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
      and (p_offre  is null or offre = p_offre)
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

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid, text, text, text) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. La clé du rapport (son empreinte seulement)
-- ---------------------------------------------------------------------
insert into public.cles_integration (nom, empreinte)
values ('rapport', '527aea23a7963d8015ae5d22b0b6d928a3be0ce0937dc8eb89cb604334b74150')
on conflict (nom) do update set empreinte = excluded.empreinte, created_at = now();

-- ---------------------------------------------------------------------
-- 3. Le rapport
-- ---------------------------------------------------------------------
-- Périmètre : les leads des deux pages de vente (formulaire, équipe Base44).
-- Les jours sont ceux de Paris. Un lead compte le jour où il arrive, une
-- vente le jour où elle est conclue, comme dans le CRM.
create or replace function public.rapport_pages(p_cle text, p_du date, p_au date)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  debut timestamptz := p_du::timestamp at time zone 'Europe/Paris';
  fin   timestamptz := (p_au + 1)::timestamp at time zone 'Europe/Paris';
  resultat json;
begin
  if not exists (select 1 from public.cles_integration
                 where nom = 'rapport'
                   and empreinte = encode(extensions.digest(coalesce(p_cle, ''), 'sha256'), 'hex')) then
    raise exception 'Clé invalide' using errcode = '28000';
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
    where l.vivier = 'formulaire' and l.equipe = 'starter'
  ),
  recus as (select * from perimetre where created_at >= debut and created_at < fin),
  ventes as (
    select * from perimetre
    where status in ('monthly', 'yearly')
      and closed_at is not null and closed_at >= debut and closed_at < fin
  ),
  offres as (select unnest(array['sirius', 'jvj']) as offre),
  par_offre as (
    select o.offre,
      (select count(*) from recus r where r.offre = o.offre)                    as leads,
      (select count(*) from recus r where r.offre = o.offre and r.dials > 0)    as appeles,
      (select count(*) from ventes v where v.offre = o.offre)                   as ventes,
      (select coalesce(sum(v.cash_collecte), 0) from ventes v where v.offre = o.offre) as cash
    from offres o
  ),
  jours as (
    select d::date as jour, o.offre,
      (select count(*) from recus r where r.offre = o.offre
         and (r.created_at at time zone 'Europe/Paris')::date = d::date)        as leads,
      (select count(*) from recus r where r.offre = o.offre and r.dials > 0
         and (r.created_at at time zone 'Europe/Paris')::date = d::date)        as appeles,
      (select count(*) from ventes v where v.offre = o.offre
         and (v.closed_at at time zone 'Europe/Paris')::date = d::date)         as ventes,
      (select coalesce(sum(v.cash_collecte), 0) from ventes v where v.offre = o.offre
         and (v.closed_at at time zone 'Europe/Paris')::date = d::date)         as cash
    from generate_series(p_du::timestamp, p_au::timestamp, interval '1 day') d, offres o
  ),
  origines as (
    select offre, origine, sum(leads) as leads, sum(ventes) as ventes, sum(cash) as cash
    from (
      select offre, origine, 1 as leads, 0 as ventes, 0::numeric as cash from recus
      union all
      select offre, origine, 0, 1, cash_collecte from ventes
    ) x
    group by offre, origine
  )
  select json_build_object(
    'offres',   (select json_agg(p) from par_offre p),
    'jours',    (select json_agg(j order by j.jour desc, j.offre) from jours j),
    'origines', coalesce((select json_agg(s order by s.leads desc, s.origine) from origines s), '[]'::json),
    'maj',      now()
  ) into resultat;

  return resultat;
end;
$$;

revoke all on function public.rapport_pages(text, date, date) from public;
grant execute on function public.rapport_pages(text, date, date) to anon, authenticated;

-- PostgREST recharge la liste des fonctions.
notify pgrst, 'reload schema';

-- Vérification : les chiffres de ce mois.
select offre, count(*) as leads from public.leads
where created_at >= date_trunc('month', now()) group by offre order by offre;

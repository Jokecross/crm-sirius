-- =====================================================================
--  Sirius — trois offres : Mensuel Builder, Annuel Starter, Annuel Builder
--  À coller dans Supabase (projet Sirius) → SQL Editor → New query → Run.
--  Rejouable. À passer APRÈS 06-stats-par-page.sql.
--
--                     Cash    Setter   Commission du setter
--    Mensuel Builder  250 $   10 %     25,00 $
--    Annuel Starter   250 $   12,5 %   31,25 $
--    Annuel Builder   450 $   15 %     67,50 $
--
--  Statuts : monthly = Mensuel Builder, yearly = Annuel Starter,
--  yearly_builder = Annuel Builder.
--
--  Une nouvelle valeur d'enum ne s'utilise pas dans la transaction qui la
--  crée : ce script compare donc en texte (status::text), et la commission
--  n'est plus une colonne générée (elle exigerait la valeur dans son
--  expression). Le déclencheur la recalcule à chaque écriture du lead :
--  personne ne peut la saisir à la main.
-- =====================================================================

alter type public.lead_statut add value if not exists 'yearly_builder' after 'yearly';

-- ---------------------------------------------------------------------
-- 1. Tarif et commission, imposés par la base
-- ---------------------------------------------------------------------
alter table public.leads drop column if exists commission;
alter table public.leads add column commission numeric(10,2) not null default 0;

create or replace function public.forcer_tarif()
returns trigger
language plpgsql
as $$
begin
  new.cash_collecte := case new.status::text
    when 'monthly'        then 250
    when 'yearly'         then 250
    when 'yearly_builder' then 450
    else 0
  end;
  new.commission := case new.status::text
    when 'monthly'        then round(new.cash_collecte * 0.10, 2)
    when 'yearly'         then round(new.cash_collecte * 0.125, 2)
    when 'yearly_builder' then round(new.cash_collecte * 0.15, 2)
    else 0
  end;
  return new;
end;
$$;

drop trigger if exists trg_forcer_tarif on public.leads;
create trigger trg_forcer_tarif
  before insert or update on public.leads
  for each row execute function public.forcer_tarif();

-- Recalcule les ventes déjà enregistrées (le déclencheur fait le calcul).
update public.leads set cash_collecte = cash_collecte
 where status::text in ('monthly', 'yearly', 'yearly_builder');

-- ---------------------------------------------------------------------
-- 2. La date de vente
-- ---------------------------------------------------------------------
create or replace function public.marquer_vente()
returns trigger
language plpgsql
as $$
begin
  if new.status::text in ('monthly', 'yearly', 'yearly_builder') then
    -- Première vente : on horodate. Un changement d'offre ne redate pas
    -- la vente, elle a bien eu lieu au premier closing.
    if new.closed_at is null then new.closed_at := now(); end if;
  else
    -- Le lead sort des statuts de vente : la vente n'a pas eu lieu.
    new.closed_at := null;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Une vente en Annuel Builder peut recevoir sa facture
-- ---------------------------------------------------------------------
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
        and l.status::text in ('monthly', 'yearly', 'yearly_builder')
    )
  );

-- ---------------------------------------------------------------------
-- 4. Les chiffres
-- ---------------------------------------------------------------------
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
    where status::text in ('monthly', 'yearly', 'yearly_builder')
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
      count(*) filter (where status::text in
        ('follow_up','monthly','yearly','yearly_builder','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*) filter (where status::text = 'yearly_builder') as yearly_builder,
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
    'yearly_builder',   v.yearly_builder,
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
                          then round((v.yearly + v.yearly_builder)::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

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
    where status::text in ('monthly', 'yearly', 'yearly_builder')
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
  ),
  formules as (
    select offre, status::text as formule, count(*) as ventes, sum(cash_collecte) as cash, sum(commission) as commissions
    from ventes group by offre, status
  )
  select json_build_object(
    'offres',   (select json_agg(p) from par_offre p),
    'jours',    (select json_agg(j order by j.jour desc, j.offre) from jours j),
    'origines', coalesce((select json_agg(s order by s.leads desc, s.origine) from origines s), '[]'::json),
    'formules', coalesce((select json_agg(f order by f.formule, f.offre) from formules f), '[]'::json),
    'maj',      now()
  ) into resultat;

  return resultat;
end;
$$;

notify pgrst, 'reload schema';

-- Vérification : la grille.
select 'Mensuel Builder' as offre, 250 as cash, round(250 * 0.10, 2) as setter
union all select 'Annuel Starter', 250, round(250 * 0.125, 2)
union all select 'Annuel Builder', 450, round(450 * 0.15, 2);

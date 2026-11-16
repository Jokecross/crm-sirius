-- =====================================================================
--  Sirius — Hermès ouvre le bon AI Master selon l'abonnement vendu
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Le sales choisit l'abonnement sur la fiche (le statut) et note l'e-mail
--  Skool du client. Hermès voit le client dans sa liste, avec le niveau à
--  ouvrir :
--    Mensuel Builder  → AI Master Basic     (modules 1 à 8)
--    Annuel Starter   → AI Master Advanced  (modules 1 à 14)
--    Annuel Builder   → AI Master Elite     (les 20 modules)
--
--  Un lead « Skool » = équipe Skool, ou venu de la page de réservation
--  Skool (offre = 'skool', dans les Leads du jour de l'équipe Base44).
--  Il entre dans la liste d'Hermès dès qu'il a un abonnement ET un e-mail
--  Skool noté (ou, comme avant, une facture déposée).
--  Un client qui change d'abonnement revient dans la liste.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. On retire l'essai « Zapier » (jamais branché)
-- ---------------------------------------------------------------------
drop trigger if exists trg_skool_facture on public.invoices;
drop trigger if exists trg_skool_lead on public.leads;
drop function if exists public.trg_skool_facture();
drop function if exists public.trg_skool_lead();
drop function if exists public.skool_renvoyer(uuid);
drop function if exists public.skool_confirme(uuid, text);
drop function if exists public.skool_envoyer(uuid, boolean);
drop table if exists public.skool_envois;
drop table if exists public.integrations_privees;
alter table public.leads
  drop column if exists skool_envoi_at,
  drop column if exists skool_envoi_formule;

-- ---------------------------------------------------------------------
-- 1. L'abonnement pour lequel l'accès a été ouvert
-- ---------------------------------------------------------------------
alter table public.leads
  add column if not exists skool_ouvert_formule text;

comment on column public.leads.skool_ouvert_formule is
  'Le statut (monthly, yearly, yearly_builder) pour lequel l''accès Skool a été ouvert. S''il ne correspond plus au statut, Hermès rouvre le bon niveau.';

-- Les accès déjà ouverts le sont pour l'abonnement actuel.
update public.leads
   set skool_ouvert_formule = status::text
 where skool_ouvert_at is not null and skool_ouvert_formule is null;

-- ---------------------------------------------------------------------
-- 2. Qui attend son accès
-- ---------------------------------------------------------------------
create or replace function public.skool_a_ouvrir(l public.leads)
returns boolean
language sql stable security definer set search_path = public
as $$
  select (l.equipe = 'skool' or l.offre = 'skool')
     and l.status::text in ('monthly', 'yearly', 'yearly_builder')
     and (nullif(trim(l.email_skool), '') is not null
          or exists (select 1 from public.invoices i where i.lead_id = l.id))
     and (l.skool_ouvert_at is null or l.skool_ouvert_formule is distinct from l.status::text);
$$;
revoke all on function public.skool_a_ouvrir(public.leads) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Ce qu'Hermès lit : la liste, avec le niveau à ouvrir
-- ---------------------------------------------------------------------
drop function if exists public.hermes_acces_a_ouvrir(text);
create function public.hermes_acces_a_ouvrir(p_cle text)
returns table (
  lead_id         uuid,
  email_skool     text,
  prenom          text,
  nom             text,
  formule         text,   -- monthly, yearly, yearly_builder
  niveau          text,   -- basic, advanced, elite
  acces           text,   -- AI Master Basic, AI Master Advanced, AI Master Elite
  modules         text,   -- 1-8, 1-14, 1-20
  facture_le      timestamptz,
  derniere_erreur text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public.hermes_verifier(p_cle);
  return query
    select l.id, lower(coalesce(nullif(trim(l.email_skool), ''), l.email)), l.first_name, l.last_name,
           l.status::text,
           case l.status::text when 'monthly' then 'basic' when 'yearly' then 'advanced' else 'elite' end,
           case l.status::text when 'monthly' then 'AI Master Basic' when 'yearly' then 'AI Master Advanced' else 'AI Master Elite' end,
           case l.status::text when 'monthly' then '1-8' when 'yearly' then '1-14' else '1-20' end,
           (select min(i.created_at) from public.invoices i where i.lead_id = l.id),
           l.skool_erreur
    from public.leads l
    where public.skool_a_ouvrir(l)
    order by l.closed_at nulls last, l.created_at;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Ce qu'Hermès répond : ouvert, ou l'erreur rencontrée
-- ---------------------------------------------------------------------
create or replace function public.hermes_acces_ouvert(
  p_cle     text,
  p_lead_id uuid,
  p_ok      boolean default true,
  p_message text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  perform public.hermes_verifier(p_cle);
  if not exists (select 1 from public.leads l
                 where l.id = p_lead_id
                   and (l.equipe = 'skool' or l.offre = 'skool')
                   and l.status::text in ('monthly', 'yearly', 'yearly_builder')) then
    raise exception 'Lead introuvable, ou sans abonnement' using errcode = 'P0002';
  end if;
  if p_ok then
    update public.leads
       set skool_ouvert_at = now(), skool_ouvert_par = 'hermes', skool_ouvert_formule = status::text,
           skool_erreur = null, skool_erreur_at = null
     where id = p_lead_id;
  else
    update public.leads
       set skool_erreur = left(coalesce(p_message, 'Erreur sans détail'), 500), skool_erreur_at = now()
     where id = p_lead_id;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.hermes_acces_a_ouvrir(text) from public;
revoke all on function public.hermes_acces_ouvert(text, uuid, boolean, text) from public;
grant execute on function public.hermes_acces_a_ouvrir(text) to anon;
grant execute on function public.hermes_acces_ouvert(text, uuid, boolean, text) to anon;

notify pgrst, 'reload schema';

-- Vérification : les clients qu'Hermès verra à son prochain passage.
select l.first_name as prenom, l.status::text as abonnement,
       coalesce(nullif(trim(l.email_skool), ''), l.email) as email_skool
  from public.leads l
 where public.skool_a_ouvrir(l)
 order by l.created_at;

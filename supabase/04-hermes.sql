-- =====================================================================
--  Sirius — Hermès (l'agent d'Anthony) ouvre les accès Skool
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Avant, les clients envoyaient leur facture en DM sur Skool et Hermès la
--  vérifiait avant d'ouvrir les modules. Maintenant le paiement se fait en
--  appel : le setter vérifie, dépose la facture dans le CRM et note
--  l'e-mail du compte Skool du client. Hermès ne vérifie plus rien, il
--  ouvre l'accès.
--
--  Hermès n'a PAS de compte dans le CRM : il ne voit ni les leads, ni les
--  téléphones de l'équipe Base44. Il a une clé à lui et deux fonctions :
--    hermes_acces_a_ouvrir(p_cle)              la liste à traiter
--    hermes_acces_ouvert(p_cle, p_lead_id, …)  « c'est ouvert » (ou l'erreur)
--  La clé n'est pas dans ce fichier : seule son empreinte SHA-256 y est.
--  Changer de clé = remplacer l'empreinte ci-dessous et relancer.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sur le lead : l'e-mail Skool et l'état de l'accès
-- ---------------------------------------------------------------------
alter table public.leads
  add column if not exists email_skool       text,
  add column if not exists skool_ouvert_at   timestamptz,
  add column if not exists skool_ouvert_par  text,          -- 'hermes' ou le prénom de qui l'a fait à la main
  add column if not exists skool_erreur      text,          -- ce qu'Hermès a répondu quand ça n'a pas marché
  add column if not exists skool_erreur_at   timestamptz;

alter table public.leads drop constraint if exists leads_email_skool_format;
alter table public.leads add constraint leads_email_skool_format check (
  email_skool is null
  or (email_skool ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' and char_length(email_skool) <= 160));

comment on column public.leads.email_skool is
  'E-mail du compte Skool du client, noté par le setter en appel. Hermès l''utilise pour ouvrir les modules.';

create index if not exists leads_skool_a_ouvrir_idx on public.leads (equipe)
  where equipe = 'skool' and skool_ouvert_at is null;

-- ---------------------------------------------------------------------
-- 2. La clé d'Hermès (son empreinte seulement)
-- ---------------------------------------------------------------------
create table if not exists public.cles_integration (
  nom        text primary key,
  empreinte  text not null,            -- sha256 hexadécimal de la clé
  created_at timestamptz not null default now()
);
alter table public.cles_integration enable row level security;
revoke all on public.cles_integration from anon, authenticated;

insert into public.cles_integration (nom, empreinte)
values ('hermes', '50acd907dd5c04e4c29e1111cb1b0909d21e8c9b5320be0d6cb624be9effe150')
on conflict (nom) do update set empreinte = excluded.empreinte, created_at = now();

create or replace function public.hermes_verifier(p_cle text)
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.cles_integration
                 where nom = 'hermes'
                   and empreinte = encode(extensions.digest(coalesce(p_cle, ''), 'sha256'), 'hex')) then
    raise exception 'Clé invalide' using errcode = '28000';
  end if;
end;
$$;
revoke all on function public.hermes_verifier(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Ce qu'Hermès lit : les clients Skool payés, facture déposée, accès
--    pas encore ouvert. Rien d'autre.
-- ---------------------------------------------------------------------
create or replace function public.hermes_acces_a_ouvrir(p_cle text)
returns table (
  lead_id        uuid,
  email_skool    text,
  prenom         text,
  nom            text,
  formule        text,
  facture_le     timestamptz,
  derniere_erreur text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public.hermes_verifier(p_cle);
  return query
    select l.id, coalesce(l.email_skool, l.email), l.first_name, l.last_name,
           l.status::text, i.created_at, l.skool_erreur
    from public.leads l
    join public.invoices i on i.lead_id = l.id
    where l.equipe = 'skool'
      and l.skool_ouvert_at is null
    order by i.created_at;
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
  if not exists (select 1 from public.leads l join public.invoices i on i.lead_id = l.id
                 where l.id = p_lead_id and l.equipe = 'skool') then
    raise exception 'Lead introuvable, ou sans facture' using errcode = 'P0002';
  end if;
  if p_ok then
    update public.leads
       set skool_ouvert_at = coalesce(skool_ouvert_at, now()), skool_ouvert_par = coalesce(skool_ouvert_par, 'hermes'),
           skool_erreur = null, skool_erreur_at = null
     where id = p_lead_id;
  else
    update public.leads
       set skool_erreur = left(coalesce(p_message, 'Erreur sans détail'), 500), skool_erreur_at = now()
     where id = p_lead_id and skool_ouvert_at is null;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.hermes_acces_a_ouvrir(text) from public;
revoke all on function public.hermes_acces_ouvert(text, uuid, boolean, text) from public;
grant execute on function public.hermes_acces_a_ouvrir(text) to anon;
grant execute on function public.hermes_acces_ouvert(text, uuid, boolean, text) to anon;

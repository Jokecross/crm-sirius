-- =====================================================================
--  Sirius — les événements d'Affiliate Consulting (Base44)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Étape 1 : on écoute. La fonction affiliate-webhook range ici chaque
--  événement tel quel (inscription, achat, annulation), sans toucher aux
--  leads. Le rapprochement avec les ventes du CRM viendra ensuite, quand on
--  aura vu ce qu'Affiliate Consulting envoie vraiment.
--
--  Lecture réservée aux comptes qui ont staff.voit_affiliate (22-affiliate-
--  acces.sql). L'écriture ne passe que par la fonction.
-- =====================================================================

create table if not exists public.affiliate_events (
  id        bigserial primary key,
  recu_at   timestamptz not null default now(),
  methode   text,
  type      text,
  payload   jsonb not null default '{}'::jsonb,
  brut      text,
  entetes   jsonb not null default '{}'::jsonb
);

create index if not exists affiliate_events_recu_idx on public.affiliate_events (recu_at desc);

alter table public.affiliate_events enable row level security;
revoke all on public.affiliate_events from anon, authenticated;
grant select on public.affiliate_events to authenticated;

-- La lecture est ouverte par 22-affiliate-acces.sql (staff.voit_affiliate).

-- Vérification : la table est là, vide.
select count(*) as evenements from public.affiliate_events;

-- ---------------------------------------------------------------------
-- 21b. L'identifiant d'envoi (X-AC-Delivery) : un envoi retenté garde le
--      même, on ne l'enregistre qu'une fois.
-- ---------------------------------------------------------------------
alter table public.affiliate_events add column if not exists delivery text;
alter table public.affiliate_events add column if not exists signature_ok boolean;
create unique index if not exists affiliate_events_delivery_idx on public.affiliate_events (delivery);

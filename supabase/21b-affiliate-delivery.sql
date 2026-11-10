-- =====================================================================
--  Sirius — Affiliate Consulting : identifiant d'envoi et signature
--  À coller dans Supabase → SQL Editor → Run. Rejouable.
--  Un envoi retenté garde le même X-AC-Delivery : on ne le garde qu'une fois.
-- =====================================================================
alter table public.affiliate_events add column if not exists delivery text;
alter table public.affiliate_events add column if not exists signature_ok boolean;
create unique index if not exists affiliate_events_delivery_idx on public.affiliate_events (delivery);

select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'affiliate_events' order by ordinal_position;

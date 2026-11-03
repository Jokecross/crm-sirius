-- =====================================================================
--  Sirius — deux pages de vente dans le même CRM : Sirius et JVJ
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Chaque lead garde la page qui l'a amené (`offre`). Les leads déjà en
--  base et la page Sirius, qui n'envoie rien, restent à 'sirius'. Les deux
--  pages déposent dans l'équipe Base44 (`starter`), la règle du formulaire
--  public ne change pas.
--  Les colonnes de suivi séparent ce que la page mettait dans `page_url`.
-- =====================================================================

alter table public.leads add column if not exists offre text not null default 'sirius';
alter table public.leads drop constraint if exists leads_offre_check;
alter table public.leads add constraint leads_offre_check
  check (offre in ('sirius', 'jvj'));
comment on column public.leads.offre is
  'La page de vente d''origine : sirius (lpsirius) ou jvj (pageventejvj).';

alter table public.leads add column if not exists ref          text;
alter table public.leads add column if not exists utm_source   text;
alter table public.leads add column if not exists utm_medium   text;
alter table public.leads add column if not exists utm_campaign text;
alter table public.leads add column if not exists utm_content  text;
alter table public.leads add column if not exists utm_term     text;

alter table public.leads drop constraint if exists leads_suivi_len;
alter table public.leads add constraint leads_suivi_len check (
  coalesce(char_length(ref), 0)          <= 120 and
  coalesce(char_length(utm_source), 0)   <= 120 and
  coalesce(char_length(utm_medium), 0)   <= 120 and
  coalesce(char_length(utm_campaign), 0) <= 120 and
  coalesce(char_length(utm_content), 0)  <= 120 and
  coalesce(char_length(utm_term), 0)     <= 120
);

create index if not exists leads_offre_idx on public.leads (offre, created_at desc);

-- Vérification : les leads par page.
select offre, count(*) as leads from public.leads group by offre order by offre;

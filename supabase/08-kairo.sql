-- =====================================================================
--  Les prompts de la page « Si ça ne marche pas » du parcours Kairo.
--  Rejouable. Les prompts eux-mêmes ne sont pas ici : le dépôt est public.
--  Ils se chargent avec « Espace Membre Sirius/scripts/kairo-prompts.sql ».
-- =====================================================================

alter table public.workshop_reglages
  add column if not exists prompts_sos jsonb not null default '{}'::jsonb;

comment on column public.workshop_reglages.prompts_sos is
  'Les prompts de la page « Si ça ne marche pas », par identifiant (SOS_BUG…).';

# CRM des setters — Sirius (premier client en 7 jours)

Back-office des setters d'Anthony Sirius, repris tel quel du CRM Marcuus
(`~/CRM Marcuus`, non modifié), lui-même repris de Mexed. Un seul fichier
(`index.html`), sans build : Vercel le sert tel quel. Il lit et écrit dans le
projet Supabase d'Anthony, le même que la page de vente (`~/Page de vente Sirius`)
et l'espace membre (`~/Espace Membre Sirius`).

```
index.html                         le CRM (HTML, CSS, JS)
supabase/INSTALLATION.sql          toute la base : leads, CRM, espace membre, réservations
supabase/01-formulaire-base44-seulement.sql   (déjà dans INSTALLATION, section Y)
supabase/02-reservations-skool.sql            (déjà dans INSTALLATION, section Z)
supabase/remise-a-zero.sql         vide les données de test
scripts/creer-comptes.mjs          crée les comptes de l'équipe
scripts/equipe.json                la liste de l'équipe
```

## Les deux équipes

| Équipe | Clé en base | Ce qu'elle travaille |
|---|---|---|
| **Base44** | `starter` | les leads du formulaire de la page de vente : vivier « Leads du jour », compte à rebours de 10 minutes, le premier setter qui prend le lead l'a pour lui |
| **Skool** | `skool` | les appels réservés sur son calendrier : chaque setter a son lien `/rdv/<code>`, la personne choisit un créneau libre, le lead arrive dans l'onglet **Rendez-vous** du setter, déjà à lui. Saisie à la main possible aussi (pipeline). |

Les deux sont étanches : un setter ne voit jamais les leads de l'autre équipe.
La séparation vit dans les règles RLS de la base, pas seulement dans
l'interface. Les administrateurs voient les deux et basculent de l'une à
l'autre. Un setter peut être ouvert aux deux avec `"equipes": ["starter", "skool"]`.

## Le calendrier de l'équipe Skool

1. Le setter remplit ses **Dispos** (onglet Dispos), comme toute l'équipe :
   ses créneaux de la semaine, à son heure à lui.
2. En haut de l'onglet, **son lien de réservation** :
   `https://lpsirius.vercel.app/rdv/<code>` (boutons Copier et WhatsApp). Le
   code se tire du prénom (`staff.rdv_code`, « Mathéo » → `mateo`, `mateo2` si
   pris) ; un admin peut le changer dans la table `staff`.
3. La personne qui ouvre le lien (`rdv.html` de la page de vente) voit les
   créneaux libres, à son heure, choisit, laisse prénom, nom, téléphone,
   e-mail. Elle peut ajouter l'appel à son agenda (Google, Apple, Outlook).
4. Le lead arrive dans l'équipe Skool, attribué au setter, avec `rdv_at`.
   L'onglet **Rendez-vous** liste les appels du jour et à venir, le plus
   proche en haut, avec un badge pour ceux qui restent aujourd'hui. Dans la
   fiche, « Annuler le rendez-vous » libère le créneau.

Les créneaux = les dispos découpées au pas de la durée d'un appel, moins les
rendez-vous pris, le préavis et l'horizon. Réglables par un admin en haut de
Dispos (équipe Skool choisie) : **30 min** par appel, **60 min** de préavis,
**14 jours** d'horizon par défaut.

Côté base : le public n'a accès qu'à deux fonctions, `rdv_calendrier(code)`
(prénom du setter, durée, créneaux libres) et `rdv_reserver(...)`, qui
revérifie le créneau sous verrou (deux visiteurs sur le même créneau : le
second reçoit « Ce créneau vient d'être pris ») et refuse un deuxième appel à
venir pour le même numéro chez le même setter. Le formulaire public de la page
de vente, lui, ne peut toujours déposer que chez Base44.

## Le parcours d'un lead Base44

1. Le formulaire de la page de vente insère une ligne dans `leads`
   (équipe `starter` = Base44, vivier `formulaire`).
2. Le lead apparaît en temps réel dans **Leads du jour**, avec un compte à
   rebours de 10 minutes.
3. Le setter l'appelle, change le statut. Une vente **Monthly** vaut 200 $
   (10 % de commission, 20 $), une vente **Yearly** 250 $ (15 %, 37,50 $),
   repris de Mexed (à confirmer pour Sirius). C'est la base qui fixe le
   montant et la commission.
4. Pendant l'appel, le setter ouvre l'espace membre → `/admin` → Invitations :
   il génère le lien de l'élève.

## Installer

1. Projet Supabase d'Anthony → **SQL Editor** → coller
   `supabase/INSTALLATION.sql` → **Run**. Rejouable (testé deux fois de suite
   sur une base vierge).
2. Authentication → Sign In / Providers → désactiver **Allow new users to
   sign up**.
3. Renseigner `SUPABASE_URL` et `SUPABASE_ANON` en haut du script de
   `index.html` (tant qu'ils sont vides, la connexion affiche « Configuration
   Supabase manquante »), ainsi que dans la page de vente (`index.html` **et**
   `rdv.html`) et le `.env` de l'espace membre. Puis `ESPACE_URL`, une fois
   l'espace membre en ligne.
4. Remplir `scripts/equipe.json` (un objet par personne, `"equipe": "starter"`
   pour Base44 ou `"skool"` pour Skool), puis créer les comptes :

   ```
   SUPABASE_URL="…" SUPABASE_SERVICE_ROLE_KEY="…" node scripts/creer-comptes.mjs
   ```

   Les mots de passe sont écrits dans `scripts/comptes.csv`, ignoré par git.
   `MDP_PRENOM=1` donne `prénom123` aux setters (risqué : devinable).

## Retiré par rapport à Mexed

L'onglet **Automatique** (le parcours sans appel des numéros africains) : la page
Sirius n'a pas ce parcours. Le code et les tables restent, inutilisés.

# Hermès → CRM Sirius : ouvrir les accès Skool

Le paiement se fait maintenant en appel. Le setter vérifie la facture, la dépose
dans le CRM et note l'e-mail du compte Skool du client. **Hermès ne vérifie
plus de facture** : il lit la liste des clients à débloquer, ouvre leurs
modules sur Skool, puis le dit au CRM.

Hermès n'a pas de compte dans le CRM. Il a une clé à lui (`HERMES_CLE`,
transmise à part, jamais dans un message public) et deux appels.

```
URL      = https://mmpazpnzkmianenkfyiv.supabase.co
ANON     = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1tcGF6cG56a21pYW5lbmtmeWl2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMzMDgwOTcsImV4cCI6MjEwODg4NDA5N30.UhmwlOXXjj-q6MB1qR_uBNCd7anEkgYdk2Egp_9R6RA
```

(`ANON` est la clé publique du projet, la même que dans le CRM : elle ne donne
accès à rien sans `HERMES_CLE`.)

## 1. La liste des accès à ouvrir (toutes les 5 minutes, par exemple)

```bash
curl -s -X POST "$URL/rest/v1/rpc/hermes_acces_a_ouvrir" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"p_cle": "'"$HERMES_CLE"'"}'
```

Réponse : un tableau, le plus ancien en premier. Vide = rien à faire.

Tout client de la liste reçoit le même accès : `formule` (mensuel ou annuel) sert à
nos comptes, pas au déblocage. Hermès retrouve le membre par `email_skool`.

```json
[
  {
    "lead_id": "0be0cf88-f410-4c36-964f-7bce20bb5e3f",
    "email_skool": "lea@mail.fr",
    "prenom": "Léa",
    "nom": "Martin",
    "formule": "monthly",
    "facture_le": "2026-10-30T09:12:00+00:00",
    "derniere_erreur": null
  }
]
```

## 2. Dire au CRM que c'est fait

Accès ouvert :

```bash
curl -s -X POST "$URL/rest/v1/rpc/hermes_acces_ouvert" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"p_cle": "'"$HERMES_CLE"'", "p_lead_id": "0be0cf88-f410-4c36-964f-7bce20bb5e3f"}'
```

Le client sort de la liste, et sa fiche affiche « Accès Skool ouvert par Hermès ».

Échec (membre introuvable sur Skool, etc.) :

```bash
  -d '{"p_cle": "…", "p_lead_id": "…", "p_ok": false, "p_message": "Membre introuvable sur Skool"}'
```

Le client reste dans la liste, et le setter voit le message en rouge dans la
fiche pour corriger l'e-mail Skool. Hermès réessaie au passage suivant.

## Erreurs

| Réponse | Sens |
|---|---|
| `Clé invalide` | `HERMES_CLE` fausse ou changée |
| `Lead introuvable, ou sans facture` | `lead_id` inconnu, ou pas un client Skool avec facture |

# Réflexion (thinking) sur Qwen3.6-27B-NVFP4-FR — quand l'activer, quand l'éviter

**Date** : 2026-07-15 · **Modèle** : `Qwen3.6-27B-NVFP4-FR` (W4A4) + drafter DSpark-FR n=8, image vLLM avec fix
[#48361](https://github.com/vllm-project/vllm/pull/48361) · **Nœud** : DGX Spark GB10 (local)
**Méthode** : A/B thinking ON vs OFF sur le même prompt, fenêtre 128k, `temperature=0.6`.

## Comment activer la réflexion (vLLM)

Par requête, sans changer la config serveur (`enable_thinking` reste `false` par défaut) :
```json
{ "chat_template_kwargs": { "enable_thinking": true } }
```
⚠️ Le raisonnement revient dans le champ **`reasoning`** de la réponse (et **non** `reasoning_content` sur
cette version). Le champ peut être vide si le budget de sortie est épuisé avant la fin.

## Résultat 1 — Analyse politique : la réflexion **aide nettement**

Tâche : analyse structurée d'un communiqué (procédés rhétoriques, présupposés, affirmations à vérifier,
glissements, cadrage idéologique).

| | Thinking ON | Thinking OFF |
|---|---|---|
| Latence | 220 s | 109 s |
| Tokens de complétion | 4 437 | 1 944 |
| Présupposés identifiés | **10** (dont subtils) | 5 |
| Méthodo de vérification | table détaillée, **institutions nommées**, indicateurs distingués (global/médian/quintile) | plus générique |
| Qualité de langue | propre | quelques scories (anglicismes, néologismes) |

→ Sur une tâche **analytique / décompositionnelle**, la réflexion apporte exhaustivité, précision
terminologique et rigueur méthodologique. Le surcoût (~2× la latence) est justifié.

## Résultat 2 — Rédaction : la réflexion **nuit**

Tâche : éditorial argumenté de 300 mots (thèse, deux contre-arguments réfutés, chute mémorable, prose continue).

| | Thinking ON (budget large) | Thinking OFF |
|---|---|---|
| Latence | 199 s | **40 s** |
| Raisonnement | **21 375 caractères** pour un texte de 300 mots | — |
| Résultat | correct mais dense, ~330 mots | **complet, dans le format, chute plus percutante** |

→ Sur une tâche **créative / rhétorique**, la réflexion sur-planifie (5× la latence pour un résultat égal
ou inférieur). Le mode direct produit une prose plus nette, dans les contraintes, et plus élégante.

## Observations transversales

1. **Le corps FR-calibré raisonne en anglais** puis répond en français — tous les blocs `reasoning`
   observés sont en anglais. Fonctionnel, mais à savoir : le raisonnement n'est pas dans la langue cible.
2. **Budget de sortie critique** : la réflexion consomme 5–7k tokens. Il faut `max_tokens` ≥ 6000, sinon
   la réponse finale est tronquée (`finish_reason=length`). C'est le budget de **sortie** qu'il faut
   élargir, pas nécessairement la fenêtre de contexte.

## Fenêtre de contexte : 64k suffit à la réflexion, 128k pour les longues entrées

Le raisonnement le plus lourd mesuré est **~5k tokens** — soit ~8 % d'une fenêtre de 64k. Ce n'est donc pas
le `max-model-len` qui contraint la réflexion, mais le budget de sortie (ci-dessus). La taille de fenêtre se
choisit sur l'**entrée**, pas sur le raisonnement :

- **64k** : marge énorme pour la réflexion + entrées courantes (article, communiqué, conversation), et
  ~2× la concurrence de 128k à budget KV égal. **Défaut recommandé.**
- **128k** : préférable seulement pour des **entrées longues** — documents de 60+ pages, gros contexte
  injecté par RAG, ou boucles agentiques multi-tours profondes (tool-calling qui accumule le contexte).

Rappel : `max-model-len` est un plafond, pas une réservation (le KV est alloué à la longueur réelle) — mais
il abaisse la concurrence planifiée et laisse une requête géante monopoliser le KV.

## Recommandation

**Activation sélective de la réflexion par type de tâche** : ON pour analyse / raisonnement / vérification,
OFF pour rédaction et échanges courants (latence + qualité). Un routage par type de tâche serait l'idéal.

## À venir

Volet non couvert ici : interaction avec un **graph RAG via MCP** (planification et enchaînement d'appels
d'outils sous réflexion) — à mesurer séparément, y compris la croissance réelle du contexte sur une session
agentique multi-tours (pour trancher 64k vs 128k sur ce cas précis).

# Tool-calling 43/100 — cause racine : le drafter dspark (spéculatif NON-lossless)

**Date** : 2026-07-14 · **Nœud** : GB10 (nœud local) · **Outil** : tool-eval-bench v1.3.2 (SeraphimSerapis), 69 scénarios, `--parallel 1 --seed 42`
**Déclencheur** : score tool-eval prod 27B = 44,2 % (doc V1_PROD_BENCH_ISOLE) vs un run FP8 externe à 91/100.

## Verdict

Le **drafter de décodage spéculatif dspark** casse le tool-calling. Il n'est **pas output-lossless** : il coûte ~43 points sur tool-eval, quel que soit le corps.

## Preuve — 2×2 contrôlé (mêmes conditions, mes mesures)

| Corps | + dspark n=8 | − dspark |
|---|---|---|
| **Qwen3.6-27B-NVFP4-FR** (prod) | **43** ❌ | **86** ✅ |
| **Qwen3.6-27B-FP8** | **43** ❌ | ~91 ✅ (run externe) |
| unsloth-Qwen3.6-35B-A3B-NVFP4 (W4A4, no draft) | — | **89** ✅ |

- **Variable unique** : NVFP4-FR passe de 43 → 86 en ne retirant QUE le drafter (corps/quantif/calibration identiques). Zéro confound.
- Le corps FP8 ne répare rien avec le drafter (43) — le corps n'est pas le problème.
- Les deux corps NVFP4 sont **W4A4 identiques** (`input_activations num_bits:4`) : W4A4 est innocenté (35B W4A4 sans draft = 89).

## Hypothèses écartées en chemin

1. ~~NVFP4 / W4A4 quantif~~ — RÉFUTÉ : 35B W4A4 = 89.
2. ~~Harnais / parser qwen3_coder / architecture~~ — RÉFUTÉ : FP8 27B sans draft = 91.
3. ~~Calibration FR~~ — RÉFUTÉ : NVFP4-FR sans draft = 86 (le corps FR est sain).

## Signature du défaut

Catégories effondrées AVEC drafter (27B) : **Parameter Precision 0 %, Multi-Step Chains 0 %**, Context & State 25 %, Autonomous Planning 17 %.
Ces mêmes catégories SANS drafter : Parameter Precision **100 %**, Multi-Step 75 %, Context & State 90 %.

## Mécanisme exact — RÉVISÉ 2026-07-14 (triangulation code + GitHub + littérature)

⚠️ **Hypothèse initiale « acceptance permissive » RÉFUTÉE.** Inspection du code (image `...dspark-20260705`) : le rejection sampler tourne en mode `standard` (défaut, `config/speculative.py:208`), **mathématiquement exact** (`rejection_sampler_utils.py` `_rejection_kernel` : greedy accepte ssi draft==argmax cible, sinon substitue l'argmax ; sampling = test de Leviathan exact). Les modes lossy (`synthetic`) ne sont PAS activés. L'acceptance n'est pas en cause.

**Cause racine réelle : corruption de l'état récurrent GDN/Mamba lors du rejet de drafts.** Sur un corps hybride, la passe spéculative avance l'état SSM/GDN de **tous les N tokens proposés**, mais **il n'existe aucun mécanisme pour rembobiner l'état récurrent à la position du dernier token accepté** quand des drafts sont rejetés → l'état se désynchronise → les logits de la cible eux-mêmes deviennent faux → même une acceptance greedy exacte produit une mauvaise sortie. Tolérable en prose, fatal sur paramètre/structure exact.
- Code local : rollback via `num_accepted_tokens` dans `qwen_gdn_linear_attn.py:1344/1455` (kernels conv + delta-rule) + migration `mamba_hybrid.py`. Garde-fou explicite `mamba_hybrid.py:138-142` (« DS conv state layout does not support ... speculative decoding ») → hybride+spec = chemin partiellement non supporté.
- **Bug KNOWN upstream** : issue racine **#43559** (accuracy −20 %, tool-eval 90→50 %, MTP + prefix caching sur Qwen3.6 hybride). Notre corps exact dans **#46249** (Qwen3.6-27B tool calls fail avec MTP). Tool-call leakage **#47194**. Même symptôme sur 122B **#35800**. Preuve du mécanisme rollback sur short_conv/LFM2 **#44296**. Crash GDN TP≥2 **#41190**.
- **DEUX mécanismes** : (1) **corruption via prefix-cache** (#43559) — le rollback écrit un état corrompu qui devient hash-reachable → propagé par le prefix caching ; **n'apparaît QUE si `--enable-prefix-caching` actif** (notre cas). (2) **rollback non-lossless pur** au rejet — présent même sans prefix cache.
- Bug de CLASSE connexe (séparé) : spec × structured-output timing off-by-one **#44927 / #27969** (le FSM grammaire n'avance pas ; mitigé en désactivant spec ou thinking).

## Cartographie de remédiation

### Tiroir 0 — Test décisif à ZÉRO patch — ✅ FAIT 2026-07-14 : MITIGATION TROUVÉE
Drafter ON + **`--no-enable-prefix-caching`** → tool-eval = **91/100 ★★★★★** (Parameter Precision 100 %, Multi-Step 100 %, Structured Output 100 %).

| Config | tool-eval |
|---|---|
| dspark + prefix-cache ON (prod) | 43 |
| **dspark + prefix-cache OFF** | **91** |
| sans dspark + prefix-cache ON | 86 |

**→ Mécanisme (1) #43559 CONFIRMÉ dominant.** Désactiver le prefix caching (flag `--no-enable-prefix-caching`, **zéro patch, zéro rebuild, réversible**) récupère INTÉGRALEMENT le tool-calling **en gardant le drafter** (donc les ~18 tok/s). Le drafter n'était jamais le vrai coupable : c'est l'interaction **prefix-caching × spec-decode × hybride GDN** qui est cassée (align mode `mamba_cache_mode`). Corps NVFP4-FR sain à 91.

**Coût de la mitigation** : perte du prefix caching = re-prefill complet à chaque tour multi-tours (TTFT plus lent sur historiques longs ; cf bench : 13,5k tokens 10,2s→1,9s au hit). Arbitrage TTFT-multitours vs tool-calling — bien meilleur que l'arbitrage débit-vs-tool-calling initial (le décode reste rapide).

**Deploy de repro** : `deploy/qwen36-27b-nvfp4fr-dspark-NOPREFIX-toolcheck-canary-sparka-20260714/` (prod + seul `--no-enable-prefix-caching`).

### Tiroir A — Cueillette upstream (le vrai fix) — ✅ VALIDÉ 2026-07-14 : 88/100
- **#48361** cherry-pické → **tool-eval 88/100 AVEC prefix caching ON + drafter** (Param Precision 100 %, Multi-Step 100 %, Structured Output 100 %). **Récupère le tool-calling SANS rien sacrifier** (prefix caching + drafter + ~18 tok/s tous conservés). 43 → 88.
  - **Python PUR** (5 fichiers source, +90 lignes, aucun kernel CUDA) → **patchable à chaud, PAS de rebuild** (`git apply` + `docker cp` + `docker commit`). S'applique proprement sur notre base 978de833 (offsets seulement).
  - Image patchée prête : **`vllm-node-main978de833-dspark-pr48361-20260714`** (19,5 GB, via docker commit). Deploy repro + patch : `deploy/qwen36-27b-nvfp4fr-dspark-PR48361-toolcheck-canary-sparka-20260714/` (`pr48361.patch`).
  - Fichiers patchés : `v1/core/sched/scheduler.py`, `v1/core/kv_cache_coordinator.py`, `v1/core/single_type_kv_cache_manager.py`, `v1/engine/llm_engine.py`, `v1/kv_cache_interface.py`.
  - **Réserves avant promo prod** : PR OUVERT non mergé (peut évoluer) ; image via docker-commit (pas un rebuild propre) ; re-valider prose FR + débit avant de remplacer la prod ; idéalement rebâtir proprement ou bump nightly au merge de #48361.
- Compléments : **#45477** (block-aligned, le plus actif 07-14), **#48375** (read-side MambaManager).
- **#47576/#47572/#48018** (ReplaySSM) : refonte qui cache les inputs SSM au lieu de l'état → élimine le besoin de rollback. Structurel, pas un hotfix.
- Rien n'est sur `main`/nightly encore → surveiller le merge de #48361, puis bump nightly.

### Tiroir B — Contournement routeur (immédiat, zéro rebuild)
- Router les requêtes portant `tools` → endpoint NVFP4-FR **sans drafter** (86/100, ~7-12 tok/s) ; prose → endpoint avec drafter (18 tok/s). Le `qwen_router` (8088) fait déjà du multi-modèle.
- Contrainte : les deux 27B ne coexistent pas (~42 GiB chacun). Arbitrage : soit endpoint no-draft par défaut, soit no-draft dédié si trafic tool faible.

### Tiroir C — Config palliative (partiel)
- `num_speculative_tokens` plus court (n=2/4) : réduit la profondeur/fréquence de rejet → atténue peut-être la corruption (à mesurer, pas un vrai fix).
- `disable_by_batch_size` : **absent de notre version** de vLLM. `typical_acceptance` : à ne PAS activer (approximatif, aggraverait).

### Tiroir D — Validation & process
- Test **greedy logit-diff** (drafter on/off, temp 0, diff byte-à-byte) pour confirmer formellement la corruption d'état et localiser la divergence.
- **Gate obligatoire** : tout drafter/config spec passe un tool-eval AVANT promotion (le jury prose FR ne l'a jamais testé).
- Watch #43559/#48361 → bump nightly au merge.

## Angle mort du gate qualité

La campagne DSpark/NVFP4-FR a certifié « ≈FP8, jury aveugle indistinguable » — sur de la **prose éditoriale FR**. Le tool-calling est un axe orthogonal jamais testé. **Leçon : un gate qualité prose ne détecte pas l'effondrement des capacités agentiques/structurées ; tout drafter spéculatif doit passer un tool-eval avant promotion.**

## Arbitrage prod

| Config | Débit c1 | Tool-calling |
|---|---|---|
| NVFP4-FR + dspark (prod actuelle) | ~18 tok/s | 43 |
| NVFP4-FR − dspark | ~7-12 tok/s | 86 |

## Options de remédiation

1. **Router-aware** : requêtes avec `tools` → endpoint NVFP4-FR **sans drafter** (86) ; chat prose → endpoint avec drafter (18 tok/s). Deux configs du même corps, coexistence mémoire à valider.
2. **Corriger le drafter** : investiguer l'acceptance dspark (seuil, méthode de vérification) — viser un mode strictement lossless. Re-tester chaque variante au tool-eval.
3. **Balayer n** : tester si un n plus court (n=2/4) ou un autre réglage préserve le tool-calling tout en gardant un gain de débit. Un tool-eval par point.
4. **Statu quo assumé** : si le chat prod ne fait pas d'agentique/tool-calling, garder le drafter (le 43 n'impacte pas la prose). À trancher selon l'usage réel.

## Artefacts
Runs : `tool-eval-runs/tool_eval_27b_v132_refresh_*.log` (NVFP4-FR+dspark 43), `tool_eval_35b_v132_*.log` (89), `tool_eval_27bFP8_dspark_*.log` (43), `tool_eval_27bNVFP4FR_nodraft_*.log` (86). Deploys canary : `deploy/qwen36-27b-FP8-dspark-toolcheck-canary-sparka-20260714/`, `deploy/qwen36-27b-nvfp4fr-NODRAFT-toolcheck-canary-sparka-20260714/`.

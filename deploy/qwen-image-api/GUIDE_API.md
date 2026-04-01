# Qwen-Image-2512-FP8 — Guide d'utilisation API

## Informations serveur

| | |
|---|---|
| **Machine** | `spark-3f18` (DGX Spark GB10, Ubuntu 24.04) |
| **IP locale** | `192.168.1.31` |
| **Port** | `18291` |
| **GPU** | NVIDIA GB10 — 128 GB mémoire unifiée |
| **Modèle** | Qwen-Image-2512 (20B params, FP8 via TorchAO) |
| **Pipeline** | `diffusers.QwenImagePipeline` + `TorchAoConfig(Float8WeightOnlyConfig())` |
| **Authentification** | Aucune par défaut (configurable via `API_KEY` dans `.env`) |
| **Swagger UI** | `http://192.168.1.31:18291/docs` |

## Architecture mémoire

Le modèle coexiste avec le LLM Qwen3.5-35B-A3B (vLLM) sur le même GPU :

| Composant | Mémoire |
|---|---|
| Transformer (FP8, TorchAO) | ~20 GB |
| Text encoder (Qwen2.5-VL-7B, BF16) | ~16 GB |
| VAE | ~250 MB |
| vLLM Qwen3.5-35B | ~44 GB |
| **Total** | **~80 GB / 128 GB** |

Le pipeline utilise `enable_model_cpu_offload()` — seul le composant actif est sur GPU pendant l'inférence. Le VAE utilise le tiling pour éviter les pics mémoire.

## Adresse d'accès

```
http://192.168.1.31:18291
```

## Endpoints

### 1. Health check

```bash
curl http://192.168.1.31:18291/health
```

Réponse : `{"ok": true, "loaded": true}`

> `loaded: false` signifie que le modèle n'est pas encore en mémoire (il se charge au premier appel, ~20 secondes).

### 2. Générer une image (texte vers image)

```bash
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a futuristic city at night with neon lights",
    "width": 1024,
    "height": 1024,
    "steps": 28,
    "response_mode": "sync"
  }'
```

#### Paramètres

| Paramètre | Type | Défaut | Description |
|---|---|---|---|
| `prompt` | string | *requis* | Description textuelle de l'image |
| `negative_prompt` | string | `""` | Ce qu'on ne veut pas voir dans l'image |
| `width` | int | 1024 | Largeur en pixels (256–2048) |
| `height` | int | 1024 | Hauteur en pixels (256–2048) |
| `steps` | int \| null | 50 | Nombre d'étapes de diffusion (28 recommandé pour rapidité) |
| `guidance` | float \| null | 4.0 | Classifier-free guidance scale |
| `seed` | int \| null | aléatoire | Graine pour reproductibilité |
| `response_mode` | `"sync"` \| `"async"` | `"sync"` | Synchrone ou asynchrone |
| `timeout_seconds` | int | 600 | Timeout max (30–3600) |

#### Résolutions recommandées

| Ratio | Dimensions |
|---|---|
| 1:1 | 1328 x 1328 |
| 16:9 | 1664 x 928 |
| 9:16 | 928 x 1664 |
| 4:3 | 1472 x 1104 |
| 3:4 | 1104 x 1472 |
| 3:2 | 1584 x 1056 |
| 2:3 | 1056 x 1584 |

#### Réponse

```json
{
  "id": "1641f43edb8a4a28",
  "status": "completed",
  "prompt_id": "1641f43edb8a4a28",
  "result_url": "http://127.0.0.1:18291/v1/images/jobs/1641f43edb8a4a28/result",
  "error": null
}
```

### 3. Récupérer l'image

```bash
curl -o image.png http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}/result
```

### 4. Consulter le statut d'un job

```bash
curl http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}
```

Statuts : `queued` → `running` → `completed` | `failed`

### 5. Mode asynchrone

```bash
# Lancer
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a mountain at dawn", "response_mode": "async"}'

# Polling
curl http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}

# Télécharger
curl -o image.png http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}/result
```

### 6. Negative prompt (CFG)

```bash
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a photorealistic portrait of a woman in a garden",
    "negative_prompt": "low quality, deformed, blurry, bad anatomy",
    "width": 1024,
    "height": 1024,
    "steps": 50,
    "guidance": 5.0,
    "response_mode": "sync"
  }'
```

## Exemples de code

### Python

```python
import requests

API = "http://192.168.1.31:18291"

resp = requests.post(f"{API}/v1/images/generations", json={
    "prompt": "a mountain landscape at dawn, cinematic lighting",
    "negative_prompt": "low quality, blurry",
    "width": 1664,
    "height": 928,
    "steps": 28,
    "guidance": 4.0,
    "response_mode": "sync",
})
data = resp.json()

if data["status"] == "completed":
    img = requests.get(f"{API}/v1/images/jobs/{data['id']}/result")
    with open("output.png", "wb") as f:
        f.write(img.content)
    print(f"Image sauvegardée : output.png")
else:
    print(f"Erreur : {data['error']}")
```

### JavaScript (fetch)

```javascript
const API = "http://192.168.1.31:18291";

const resp = await fetch(`${API}/v1/images/generations`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    prompt: "a small orange cat sitting on a windowsill at sunset",
    width: 1024,
    height: 1024,
    steps: 28,
    response_mode: "sync",
  }),
});
const data = await resp.json();

if (data.status === "completed") {
  const img = await fetch(`${API}/v1/images/jobs/${data.id}/result`);
  const blob = await img.blob();
  // utiliser le blob
}
```

## Authentification (optionnelle)

1. Éditer `.env` et définir `API_KEY=votre_cle_secrete`
2. Redémarrer : `./down.sh && ./up.sh`

```bash
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "x-api-key: votre_cle_secrete" \
  -d '{"prompt": "...", "response_mode": "sync"}'
```

## Administration

| Action | Commande |
|---|---|
| Démarrer | `./up.sh` |
| Arrêter | `./down.sh` |
| Statut | `./status.sh` |
| Logs | `tail -f logs/api.log` |
| Setup initial | `./setup.sh` |

Répertoire : `/home/pablo/Projets/qwen3.5-122/deploy/qwen-image-api/`

## Performances

| Métrique | Valeur |
|---|---|
| Chargement initial (TorchAO FP8) | ~20 secondes |
| Premier step (compilation) | ~3 minutes |
| Steps suivants (1024x1024) | ~4-7 secondes/step |
| 28 steps (1024x1024) | ~6 minutes |
| 50 steps (1024x1024) | ~10 minutes |

## Notes techniques

- **Quantification** : TorchAO `Float8WeightOnlyConfig` — poids stockés en FP8 (float8_e4m3fn), compute en BF16
- **Modèle de base** : `Qwen/Qwen-Image-2512` (poids complets en local)
- **CPU offload** : les composants (transformer, text encoder, VAE) sont déchargés vers le CPU entre les inférences
- **VAE tiling** : le décodage VAE se fait par tuiles pour éviter les OOM
- **Coexistence** : fonctionne aux côtés de vLLM Qwen3.5-35B-A3B sur le même GPU

# Flux2 Klein 9B — Guide d'utilisation API

## Informations serveur

| | |
|---|---|
| **Machine** | `spark-3f18` (Ubuntu 24.04) |
| **IP locale** | `192.168.1.31` |
| **Port** | `18291` |
| **GPU** | NVIDIA GB10 |
| **Modèle** | Flux2 Klein 9B (17 GB, BF16) |
| **Authentification** | Aucune par défaut (configurable via `API_KEY` dans `.env`) |
| **Swagger UI** | `http://192.168.1.31:18291/docs` |

## Adresse d'accès

```
http://192.168.1.31:18291
```

Le serveur écoute sur `0.0.0.0:18291` — accessible depuis tout le réseau local.

## Endpoints

### 1. Health check

```bash
curl http://192.168.1.31:18291/health
```

Réponse :

```json
{"ok": true, "loaded": true}
```

> `loaded: false` signifie que le modèle n'est pas encore en mémoire GPU (il se charge au premier appel).

### 2. Générer une image (texte vers image)

```bash
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a futuristic city at night with neon lights",
    "width": 1024,
    "height": 1024,
    "response_mode": "sync"
  }'
```

#### Paramètres

| Paramètre | Type | Défaut | Description |
|---|---|---|---|
| `prompt` | string | *requis* | Description textuelle de l'image |
| `width` | int | 1024 | Largeur en pixels (256–2048) |
| `height` | int | 1024 | Hauteur en pixels (256–2048) |
| `steps` | int \| null | 4 | Nombre d'étapes de diffusion (fixé à 4 par le modèle) |
| `guidance` | float \| null | 1.0 | Guidance scale (fixé à 1.0 par le modèle) |
| `seed` | int \| null | aléatoire | Graine pour reproductibilité |
| `response_mode` | `"sync"` \| `"async"` | `"sync"` | Synchrone = attendre le résultat ; asynchrone = job en arrière-plan |
| `timeout_seconds` | int | 600 | Timeout max (30–3600) |

> **Note :** `steps` et `guidance` sont fixés par le modèle Klein 9B — les modifier n'aura pas d'effet.

#### Réponse

```json
{
  "id": "0b00f64406e0814c",
  "status": "completed",
  "prompt_id": "0b00f64406e0814c",
  "result_url": "http://127.0.0.1:18291/v1/images/jobs/0b00f64406e0814c/result",
  "error": null
}
```

### 3. Récupérer l'image générée

```bash
curl -o image.png http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}/result
```

### 4. Consulter le statut d'un job

```bash
curl http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}
```

Statuts possibles : `queued` → `running` → `completed` | `failed`

### 5. Mode asynchrone

```bash
# Lancer le job
curl -X POST http://192.168.1.31:18291/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a mountain landscape at dawn", "response_mode": "async"}'

# Polling du statut
curl http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}

# Télécharger quand status == "completed"
curl -o image.png http://192.168.1.31:18291/v1/images/jobs/{JOB_ID}/result
```

### 6. Édition d'image (img2img)

```bash
# Encoder l'image source en base64
IMAGE_B64=$(base64 -w0 source.png)

curl -X POST http://192.168.1.31:18291/v1/images/edits \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"transform into watercolor style\",
    \"image_base64\": \"$IMAGE_B64\",
    \"width\": 1024,
    \"height\": 1024,
    \"response_mode\": \"sync\"
  }"
```

## Exemples de code

### Python

```python
import requests

API = "http://192.168.1.31:18291"

# Générer une image
resp = requests.post(f"{API}/v1/images/generations", json={
    "prompt": "a mountain landscape at dawn",
    "width": 1024,
    "height": 768,
    "response_mode": "sync",
})
data = resp.json()

# Télécharger l'image
if data["status"] == "completed":
    img = requests.get(f"{API}/v1/images/jobs/{data['id']}/result")
    with open("output.png", "wb") as f:
        f.write(img.content)
    print(f"Image sauvegardée : output.png")
else:
    print(f"Erreur : {data['error']}")
```

### Python — édition d'image

```python
import base64
import requests

API = "http://192.168.1.31:18291"

with open("source.png", "rb") as f:
    image_b64 = base64.b64encode(f.read()).decode()

resp = requests.post(f"{API}/v1/images/edits", json={
    "prompt": "add a rainbow in the sky",
    "image_base64": image_b64,
    "width": 1024,
    "height": 1024,
    "response_mode": "sync",
})
data = resp.json()

if data["status"] == "completed":
    img = requests.get(f"{API}/v1/images/jobs/{data['id']}/result")
    with open("edited.png", "wb") as f:
        f.write(img.content)
```

### JavaScript (fetch)

```javascript
const API = "http://192.168.1.31:18291";

const resp = await fetch(`${API}/v1/images/generations`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    prompt: "a small orange cat sitting on a windowsill at sunset",
    width: 512,
    height: 512,
    response_mode: "sync",
  }),
});
const data = await resp.json();

if (data.status === "completed") {
  const img = await fetch(`${API}/v1/images/jobs/${data.id}/result`);
  const blob = await img.blob();
  // utiliser le blob (affichage, sauvegarde...)
}
```

## Authentification (optionnelle)

Par défaut aucune clé API n'est requise. Pour activer l'authentification :

1. Éditer `/home/pablo/Projets/qwen3.5-122/deploy/flux2-klein-api/.env`
2. Définir `API_KEY=votre_cle_secrete`
3. Redémarrer le service (`down.sh` puis `up.sh`)

Passer ensuite la clé dans le header :

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

Répertoire de travail : `/home/pablo/Projets/qwen3.5-122/deploy/flux2-klein-api/`

## Notes

- **Premier appel lent** (~2–3 min) : le modèle se charge en mémoire GPU à la demande. Les appels suivants sont rapides.
- **Images de sortie** stockées dans `/home/pablo/flux2-klein-runtime/outputs/`
- **Résolutions recommandées** : 512x512, 768x768, 1024x1024, 1024x768, 768x1024
- **Torch compile** activé (`reduce-overhead`) — le tout premier appel après chargement inclut une phase de compilation.

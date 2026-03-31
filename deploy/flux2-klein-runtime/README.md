# FLUX.2-klein Runtime

Bundle host-native pour exécuter le runtime officiel `black-forest-labs/flux2` sur le Spark local.

Ce bundle :
- embarque le repo officiel dans `vendor/flux2`
- crée un venv local
- utilise le poids `flux-2-klein-9b.safetensors`
- utilise un `AE_MODEL_PATH` explicite

Commandes :

```bash
cp .env.example .env
./setup.sh
```

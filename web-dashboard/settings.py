"""Chemins partages par les modules du dashboard."""
import os
from pathlib import Path

# Racine du depot: ORAN_REPO si defini, sinon le dossier parent de web-dashboard/.
REPO = Path(os.environ.get("ORAN_REPO", Path(__file__).resolve().parents[1]))

# Dossier des preuves et resultats ecrits par le dashboard.
PROOF_DIR = Path.home() / "oran-proof"

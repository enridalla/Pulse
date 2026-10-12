# Python reference implementation

`main.py` mirrors the signal-processing logic implemented in the iOS app and is used for offline inspection, plotting and regression testing.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

## Run

```bash
MPLBACKEND=Agg python main.py
```

Generated plots are written to `results/`, which is intentionally ignored by Git because the figures are reproducible. A representative output is kept under `../docs/sample-analysis.png`.

## Test

```bash
python -m pip install -r requirements-dev.txt
pytest -q
```

The bundled CSV files are small controlled examples intended for reproducibility and regression testing, not for making clinical-performance claims.

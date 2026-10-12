"""Regression tests for the Python reference implementation.

These tests intentionally use the sample recordings committed with the repository. They are
not a clinical validation dataset; their purpose is to catch accidental algorithm regressions.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

import pytest


ANALYSIS_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ANALYSIS_DIR / "data"

spec = importlib.util.spec_from_file_location("pulse_reference", ANALYSIS_DIR / "main.py")
assert spec and spec.loader
pulse_reference = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pulse_reference
spec.loader.exec_module(pulse_reference)


@pytest.mark.parametrize(
    ("filename", "expected_rr", "expected_hr"),
    [
        ("recording_01_rr08.csv", 7.3, 72.7),
        ("recording_02_rr12.csv", 13.1, 79.9),
        ("recording_03_rr15.csv", 15.0, 86.3),
        ("recording_04_rr20.csv", 20.2, 89.8),
        ("recording_05_rr25.csv", 25.0, 91.2),
        ("recording_06_rr30.csv", 30.1, 92.8),
    ],
)
def test_reference_outputs_remain_stable(filename: str, expected_rr: float, expected_hr: float) -> None:
    result, *_ = pulse_reference.process_file(DATA_DIR / filename)

    assert result["respiratory_rate"] == pytest.approx(expected_rr, abs=0.05)
    assert result["heart_rate"] == pytest.approx(expected_hr, abs=0.05)

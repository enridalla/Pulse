from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
import sys

import numpy as np
import matplotlib.pyplot as plt
from scipy import signal


ALGORITHM_VERSION = "5.4.0"

# Acquisition / preprocessing
MINIMUM_SAMPLE_COUNT = 200
MINIMUM_RECORDING_SECONDS = 20.0
TRIM_BEGINNING_SECONDS = 5.0
TRIM_ENDING_SECONDS = 5.0
RESAMPLING_JITTER_THRESHOLD = 0.02
ANOMALOUS_INTERVAL_ROBUST_SIGMA_FACTOR = 5.0
ANOMALOUS_INTERVAL_RELATIVE_FLOOR = 0.005

# Physiological bands
RR_SEARCH_HZ = (0.10, 1.50)       # 6...90 breaths/min
RR_FILTER_HZ = (0.08, 1.65)
HR_FILTER_HZ = (7.0, 30.0)
HR_RANGE_BPM = (40.0, 180.0)
RESPIRATION_FILTER_ORDER = 4
HEART_FILTER_ORDER = 4

# Respiration: PCA -> ACF primary, Welch verification, fixed-window persistence
WELCH_SEGMENT_SECONDS = 30.0
WELCH_OVERLAP_FRACTION = 0.5
WELCH_FREQUENCY_GRID_POINTS = 281
RR_PEAK_SEPARATION_HZ = 0.05
RR_DOMAIN_AGREEMENT_BPM = 2.5
RR_DOMAIN_AGREEMENT_FRACTION = 0.08
RR_AXIS_AGREEMENT_BPM = 2.5
RR_AXIS_AGREEMENT_FRACTION = 0.08
RR_HARMONIC_RATIO_TOLERANCE = 0.08
RR_MINIMUM_OBSERVED_CYCLES = 3.0
RR_BOUNDARY_TOLERANCE_FRACTION = 0.02
RR_LOCAL_WINDOW_SECONDS = 30.0
RR_LOCAL_HOP_SECONDS = 15.0
RR_HEART_OVERLAP_BPM = 4.0
RR_HEART_OVERLAP_FRACTION = 0.06
RR_HEART_SUBHARMONIC_MIN_RATE_BPM = 30.0
RR_HEART_SUBHARMONIC_BPM = 5.0
RR_HEART_SUBHARMONIC_FRACTION = 0.08

# Heart: automatic template selection -> NCC -> IBI; ACF only as consistency/fallback
HEART_TEMPLATE_WINDOW_SECONDS = 10.0
HEART_TEMPLATE_MINIMUM_WINDOW_SECONDS = 8.0
HEART_TEMPLATE_ENVELOPE_LOWPASS_HZ = 3.0
HEART_TEMPLATE_ENVELOPE_LOWPASS_ORDER = 2
HEART_TEMPLATE_ENVELOPE_PEAK_PROMINENCE = 0.25
HEART_TEMPLATE_MINIMUM_PEAKS = 5
HEART_TEMPLATE_CLUSTER_MINIMUM_CORRELATION = 0.30
HEART_TEMPLATE_MAXIMUM_IBI_MAD_SECONDS = 0.335
HEART_TEMPLATE_PRE_SECONDS = 0.20
HEART_TEMPLATE_POST_SECONDS = 0.50
HEART_NCC_MINIMUM_CORRELATION = 0.50
HEART_NCC_MINIMUM_PROMINENCE = 0.50
HEART_NCC_MINIMUM_PEAK_DISTANCE_FRACTION_OF_MINIMUM_IBI = 0.90
HEART_MINIMUM_BEAT_COUNT = 6
HEART_MINIMUM_TEMPLATE_CORRELATION = 0.50
HEART_MINIMUM_VALID_INTERVAL_FRACTION = 0.72
HEART_MAXIMUM_IBI_VARIABILITY = 0.24
HEART_RELIABLE_QUALITY_THRESHOLD = 0.56
HEART_CONFIRMED_MINIMUM_VALID_INTERVAL_FRACTION = 0.80
HEART_RMS_ENVELOPE_WINDOW_SECONDS = 0.10
HEART_ACF_SIGNIFICANT_PEAK_FRACTION = 0.60
HEART_ACF_MINIMUM_STRENGTH = 0.15
HEART_ACF_AGREEMENT_BPM = 4.0
HEART_ACF_AGREEMENT_FRACTION = 0.08
HEART_ACF_MINIMUM_SUPPORTING_AXES = 2
HEART_ACF_LOCAL_WINDOW_SECONDS = 15.0
HEART_ACF_LOCAL_HOP_SECONDS = 7.5
HEART_ACF_MINIMUM_LOCAL_AGREEMENT_FRACTION = 0.60

# Heart beat-sequence ambiguity checks (mirrors SignalProcessingParameters.swift)
HEART_ALTERNATING_INTERVAL_MINIMUM_RELATIVE_DIFFERENCE = 0.20
HEART_ALTERNATING_PAIR_DISPERSION_IMPROVEMENT_FACTOR = 0.60
HEART_ALTERNATING_PAIR_MAXIMUM_ROBUST_CV = 0.18
HEART_MIDPOINT_MINIMUM_SUPPORT_FRACTION = 0.60
HEART_MIDPOINT_CORRELATION_FRACTION_OF_ACCEPTED_MEDIAN = 0.85
HEART_MIDPOINT_SEARCH_FRACTION_OF_IBI = 0.16
HEART_MIDPOINT_EXPANDED_MAXIMUM_ROBUST_CV = 0.18
HEART_HARMONIC_RATIO_TOLERANCE = 0.10
HEART_AMBIGUOUS_UNIFORM_INTERVAL_CV = 0.12


def swift_rounded_int(value: float) -> int:
    if value >= 0:
        return int(np.floor(value + 0.5))
    return int(np.ceil(value - 0.5))


@dataclass
class Spectrum:
    frequencies_hz: np.ndarray
    power: np.ndarray

    def peak(self, lo: float, hi: float):
        mask = (self.frequencies_hz >= lo) & (self.frequencies_hz <= hi)
        if not np.any(mask):
            return None
        idxs = np.flatnonzero(mask)
        best = idxs[int(np.argmax(self.power[idxs]))]
        freq = float(self.frequencies_hz[best])
        value = float(self.power[best])
        if 0 < best < len(self.power) - 1:
            yl, yc, yr = self.power[best - 1], self.power[best], self.power[best + 1]
            den = yl - 2 * yc + yr
            if abs(den) > np.finfo(float).eps:
                step = self.frequencies_hz[best] - self.frequencies_hz[best - 1]
                freq = float(self.frequencies_hz[best] + 0.5 * (yl - yr) / den * step)
        return freq, value


@dataclass
class ComponentResult:
    name: str
    filtered: np.ndarray
    spectrum: Spectrum
    rate_bpm: float | None
    welch_rate_bpm: float | None
    acf_rate_bpm: float | None
    acf_strength: float
    temporal_stability: float
    local_agreeing_windows: int
    local_total_windows: int
    spectral_support: str
    peak_to_band_power_ratio: float
    first_to_second_peak_ratio: float
    domain_agreement_bpm: float | None
    quality: float
    is_reportable: bool
    is_reliable: bool


@dataclass
class HeartAnalysis:
    rate_bpm: float | None
    baseline_rate_bpm: float | None
    detected_beat_count: int
    ibi_cv: float | None
    median_correlation: float | None
    quality: float
    is_reliable: bool
    beat_times_s: np.ndarray
    normalized_signal: np.ndarray
    valid_interval_fraction: float
    method: str


def name_key(name: str) -> str:
    return "".join(c for c in name.lower() if c.isalnum())


def find_columns(header):
    keys = {name_key(h): h for h in header}
    aliases = {
        "time": ["times", "time", "timestamp", "timeseconds", "elapsedseconds"],
        "x": ["x", "ax", "accx", "accelerationx", "accelerationxg"],
        "y": ["y", "ay", "accy", "accelerationy", "accelerationyg"],
        "z": ["z", "az", "accz", "accelerationz", "accelerationzg"],
    }
    result = []
    for group in ("time", "x", "y", "z"):
        column = next((keys[a] for a in aliases[group] if a in keys), None)
        if column is None:
            raise ValueError("Required columns: time_s, acceleration_x_g, acceleration_y_g, acceleration_z_g")
        result.append(column)
    return result


def load_csv(path: Path):
    rows = []
    last_time = None
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("CSV file has no header")
        t_col, x_col, y_col, z_col = find_columns(reader.fieldnames)
        for row in reader:
            try:
                values = [float(row[c]) for c in (t_col, x_col, y_col, z_col)]
            except (ValueError, TypeError):
                continue
            if not np.all(np.isfinite(values)):
                continue
            t = values[0]
            if last_time is not None and t <= last_time:
                # Swift SamplingAnalyzer skips duplicate and non-increasing samples in input order.
                continue
            rows.append(values)
            last_time = t
    if len(rows) < MINIMUM_SAMPLE_COUNT:
        raise ValueError("Too few valid samples")
    data = np.asarray(rows, dtype=float)
    time = data[:, 0]
    axes = data[:, 1:4]
    if len(time) < MINIMUM_SAMPLE_COUNT or np.any(np.diff(time) <= 0):
        raise ValueError("Timestamps must be strictly increasing")
    return time, axes


def median_abs_deviation(values: np.ndarray) -> float:
    if len(values) == 0:
        return 0.0
    return float(1.4826 * np.median(np.abs(values - np.median(values))))


def robust_cv(values: np.ndarray) -> float:
    if len(values) == 0:
        return float("inf")
    center = float(np.median(values))
    if center <= np.finfo(float).eps:
        return float("inf")
    return median_abs_deviation(values) / center


def remove_mean(values: np.ndarray) -> np.ndarray:
    return np.asarray(values, dtype=float) - float(np.mean(values))


def uniform_sampling(time: np.ndarray, axes: np.ndarray):
    dt = np.diff(time)
    median_dt = float(np.median(dt))
    if median_dt <= np.finfo(float).eps:
        raise ValueError("Invalid timestamps")
    fs = 1.0 / median_dt
    jitter = float(np.std(dt) / median_dt)
    large_gap = bool(np.any((dt > 1.5 * median_dt) | (dt < 0.5 * median_dt)))
    should_resample = jitter > RESAMPLING_JITTER_THRESHOLD or large_gap
    if not should_resample:
        return time, axes, fs, False
    count = int(np.floor((time[-1] - time[0]) / median_dt)) + 1
    new_time = time[0] + np.arange(count) * median_dt
    new_axes = np.column_stack([np.interp(new_time, time, axes[:, i]) for i in range(3)])
    return new_time, new_axes, fs, True


def preprocess(time: np.ndarray, axes: np.ndarray, fs: float):
    start = swift_rounded_int(TRIM_BEGINNING_SECONDS * fs)
    end = len(time) - swift_rounded_int(TRIM_ENDING_SECONDS * fs)
    min_samples = int(MINIMUM_RECORDING_SECONDS * fs)
    if start < 0 or end <= start or end - start < min_samples:
        raise ValueError("Recording too short after trimming")
    return time[start:end], axes[start:end]


def detrend_linear(values: np.ndarray) -> np.ndarray:
    x = np.asarray(values, dtype=float)
    if x.ndim == 2:
        return np.column_stack([detrend_linear(x[:, i]) for i in range(x.shape[1])])
    n = len(x)
    if n <= 2:
        return remove_mean(x)
    n_d = float(n)
    sum_x = n_d * (n_d - 1.0) / 2.0
    sum_x2 = (n_d - 1.0) * n_d * (2.0 * n_d - 1.0) / 6.0
    sum_y = float(np.sum(x))
    indices = np.arange(n, dtype=float)
    sum_xy = float(np.dot(indices, x))
    denominator = n_d * sum_x2 - sum_x * sum_x
    if abs(denominator) <= np.finfo(float).eps:
        return remove_mean(x)
    slope = (n_d * sum_xy - sum_x * sum_y) / denominator
    intercept = (sum_y - slope * sum_x) / n_d
    return x - (slope * indices + intercept)



class Biquad:
    def __init__(self, b0: float, b1: float, b2: float, a1: float, a2: float):
        self.b0, self.b1, self.b2, self.a1, self.a2 = b0, b1, b2, a1, a2

    @property
    def dc_gain(self) -> float:
        den = 1.0 + self.a1 + self.a2
        return (self.b0 + self.b1 + self.b2) / den if abs(den) > np.finfo(float).eps else 0.0

    def filter(self, x: np.ndarray) -> np.ndarray:
        if len(x) == 0:
            return x.copy()
        g = self.dc_gain
        first = float(x[0])
        z1 = (g - self.b0) * first
        z2 = (self.b2 - self.a2 * g) * first
        y = np.empty_like(x, dtype=float)
        for i, xv in enumerate(x):
            out = self.b0 * xv + z1
            z1 = self.b1 * xv - self.a1 * out + z2
            z2 = self.b2 * xv - self.a2 * out
            y[i] = out
        return y


def butterworth_quality_factors(order: int) -> list[float]:
    return [1.0 / (2.0 * np.cos((2 * k + 1) * np.pi / (2 * order))) for k in range(order // 2)]


def biquad_lowpass(cutoff: float, fs: float, q: float) -> Biquad:
    w0 = 2 * np.pi * cutoff / fs
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2 * q)
    a0 = 1 + alpha
    return Biquad(((1 - cw) / 2) / a0, (1 - cw) / a0, ((1 - cw) / 2) / a0, (-2 * cw) / a0, (1 - alpha) / a0)


def biquad_highpass(cutoff: float, fs: float, q: float) -> Biquad:
    w0 = 2 * np.pi * cutoff / fs
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2 * q)
    a0 = 1 + alpha
    return Biquad(((1 + cw) / 2) / a0, (-(1 + cw)) / a0, ((1 + cw) / 2) / a0, (-2 * cw) / a0, (1 - alpha) / a0)


def odd_reflection_pad(x: np.ndarray, pad_length: int) -> np.ndarray:
    if pad_length <= 0 or len(x) == 0:
        return x.copy()
    n = len(x)
    first, last = x[0], x[-1]
    left = np.array([2 * first - x[min(i, n - 1)] for i in range(pad_length, 0, -1)])
    right = np.array([2 * last - x[max(n - 1 - i, 0)] for i in range(1, pad_length + 1)])
    return np.concatenate([left, x, right])


def filtfilt_sections(values: np.ndarray, sections: list[Biquad], pad_length: int) -> np.ndarray:
    x = np.asarray(values, dtype=float)
    if len(x) <= 3:
        return x.copy()
    pad = min(pad_length, len(x) - 1)
    y = odd_reflection_pad(x, pad)
    for section in sections:
        y = section.filter(y)
    y = y[::-1].copy()
    for section in sections:
        y = section.filter(y)
    y = y[::-1]
    return y[pad:pad + len(x)]


def bandpass_1d(values: np.ndarray, fs: float, low: float, high: float, order: int) -> np.ndarray:
    upper = min(high, 0.45 * fs)
    if upper <= low:
        raise ValueError("Invalid filter band")
    sections: list[Biquad] = []
    for q in butterworth_quality_factors(order):
        sections.append(biquad_highpass(low, fs, q))
        sections.append(biquad_lowpass(upper, fs, q))
    pad_length = max(order * 3, swift_rounded_int(fs / max(low, 0.01) * 1.5))
    return filtfilt_sections(values, sections, pad_length)


def bandpass(values: np.ndarray, fs: float, low: float, high: float, order: int) -> np.ndarray:
    x = np.asarray(values, dtype=float)
    if x.ndim == 1:
        return bandpass_1d(x, fs, low, high, order)
    return np.column_stack([bandpass_1d(x[:, i], fs, low, high, order) for i in range(x.shape[1])])


def lowpass(values: np.ndarray, fs: float, cutoff: float, order: int) -> np.ndarray:
    upper = min(cutoff, 0.45 * fs)
    sections = [biquad_lowpass(upper, fs, q) for q in butterworth_quality_factors(order)]
    pad_length = max(order * 3, swift_rounded_int(fs / upper * 1.5))
    return filtfilt_sections(np.asarray(values, dtype=float), sections, pad_length)


def _vector_norm(vector: np.ndarray) -> float:
    return float(np.sqrt(np.dot(vector, vector)))


def _normalized_vector(vector: np.ndarray) -> np.ndarray:
    vector = np.asarray(vector, dtype=float)
    norm = _vector_norm(vector)
    return vector / norm if norm > 1e-14 else np.array([1.0, 0.0, 0.0])


def _orthogonalized(vector: np.ndarray, basis: np.ndarray) -> np.ndarray:
    return np.asarray(vector, dtype=float) - float(np.dot(vector, basis)) * basis


def _dominant_eigenvector(matrix: np.ndarray, seed: np.ndarray, orthogonal_to: np.ndarray | None = None) -> np.ndarray:
    vector = _normalized_vector(seed)
    for _ in range(60):
        nxt = matrix @ vector
        if orthogonal_to is not None:
            nxt = _orthogonalized(nxt, orthogonal_to)
        norm = _vector_norm(nxt)
        if norm <= 1e-14:
            break
        nxt = nxt / norm
        change = float(np.sum(np.abs(nxt - vector)))
        vector = nxt
        if change < 1e-10:
            break
    return _normalized_vector(vector)


def principal_components(axes: np.ndarray):
    centered = np.asarray(axes, dtype=float) - np.mean(axes, axis=0)
    n = float(len(centered))
    covariance = centered.T @ centered / n

    first = _dominant_eigenvector(
        covariance,
        _normalized_vector(np.array([1.0, 1.0, 1.0])),
        None,
    )
    first_eigenvalue = float(first @ (covariance @ first))
    deflated = covariance - first_eigenvalue * np.outer(first, first)
    second_seed = _normalized_vector(_orthogonalized(np.array([1.0, -1.0, 0.5]), first))
    second = _dominant_eigenvector(deflated, second_seed, first)

    return centered @ first, centered @ second, first, second


def band_limited_candidates(axes: np.ndarray, fs: float, band: tuple[float, float], order: int):
    filtered = bandpass(detrend_linear(axes), fs, band[0], band[1], order)
    pc1, pc2, weights, _ = principal_components(filtered)
    return {
        "x": filtered[:, 0],
        "y": filtered[:, 1],
        "z": filtered[:, 2],
        "PC1-band": pc1,
        "PC2-band": pc2,
    }, weights


def acf_array(raw: np.ndarray) -> np.ndarray:
    x = remove_mean(np.asarray(raw, dtype=float))
    energy = float(np.dot(x, x))
    if energy <= np.finfo(float).eps:
        return np.zeros(len(x))
    corr = signal.correlate(x, x, mode="full", method="fft")[len(x) - 1:]
    return corr / energy


def refine_peak(y: np.ndarray, index: int) -> float:
    if index <= 0 or index >= len(y) - 1:
        return float(index)
    yl, yc, yr = y[index - 1], y[index], y[index + 1]
    den = yl - 2 * yc + yr
    if abs(den) <= np.finfo(float).eps:
        return float(index)
    return float(index + 0.5 * (yl - yr) / den)


def autocorrelation_peaks(raw: np.ndarray, fs: float) -> list[tuple[float, float]]:
    acf = acf_array(raw)
    band_lo, band_hi = RR_SEARCH_HZ
    tol = RR_BOUNDARY_TOLERANCE_FRACTION
    min_lag = max(1, int(np.floor(fs / (band_hi * (1 + tol)))) - 1)
    max_lag = min(len(acf) - 2, int(np.ceil(fs / (band_lo * (1 - tol)))) + 1)
    if min_lag + 2 >= max_lag:
        return []
    peaks = []
    expanded_lo = band_lo * (1 - tol)
    expanded_hi = band_hi * (1 + tol)
    for lag in range(min_lag + 1, max_lag):
        value = float(acf[lag])
        if value <= 0 or value < acf[lag - 1] or value < acf[lag + 1]:
            continue
        refined_lag = refine_peak(acf, lag)
        refined_frequency = fs / refined_lag if refined_lag > 0 else 0
        integer_frequency = fs / lag
        if expanded_lo <= refined_frequency <= expanded_hi:
            frequency = refined_frequency
        elif expanded_lo <= integer_frequency <= expanded_hi:
            frequency = integer_frequency
        else:
            continue
        frequency = min(band_hi, max(band_lo, frequency))
        peaks.append((frequency, min(1.0, max(0.0, value))))
    return peaks


def frequency_grid(min_hz: float, max_hz: float, points: int):
    return np.linspace(min_hz, max_hz, points)


def welch_spectrum_direct(values: np.ndarray, fs: float, grid: np.ndarray) -> Spectrum:
    n = len(values)
    if n <= 1 or len(grid) == 0:
        return Spectrum(grid, np.zeros_like(grid))
    seg_len = max(8, min(swift_rounded_int(WELCH_SEGMENT_SECONDS * fs), n))
    step = max(1, int(seg_len * (1 - WELCH_OVERLAP_FRACTION)))
    starts = list(range(0, n - seg_len + 1, step)) or [0]
    window = np.hanning(seg_len)
    scale = 1.0 / (fs * max(float(np.sum(window * window)), np.finfo(float).eps))
    idx = np.arange(seg_len)
    accumulated = np.zeros(len(grid))
    # The grid is small (281 points), so a direct band-limited DFT matches the Swift implementation.
    exponents = np.exp(-2j * np.pi * np.outer(grid / fs, idx))
    for start in starts:
        segment = values[start:start + seg_len]
        if len(segment) < seg_len:
            segment = np.pad(segment, (0, seg_len - len(segment)))
        windowed = (segment - np.mean(segment)) * window
        ft = exponents @ windowed
        accumulated += 2.0 * (np.abs(ft) ** 2) * scale
    return Spectrum(grid, accumulated / len(starts))


def local_spectral_peaks(spectrum: Spectrum) -> list[tuple[float, float]]:
    p = spectrum.power
    f = spectrum.frequencies_hz
    if len(p) == 0:
        return []
    peaks = []
    for i, value in enumerate(p):
        left = p[i - 1] if i > 0 else -np.inf
        right = p[i + 1] if i + 1 < len(p) else -np.inf
        if value >= left and value >= right:
            peaks.append((float(f[i]), float(value)))
    return peaks


def rr_frequency_tolerance_hz(freq: float) -> float:
    return max(RR_DOMAIN_AGREEMENT_BPM / 60.0, RR_DOMAIN_AGREEMENT_FRACTION * freq)


def rr_rate_tolerance_bpm(rate: float) -> float:
    return max(RR_AXIS_AGREEMENT_BPM, RR_AXIS_AGREEMENT_FRACTION * rate)


def temporal_persistence(values: np.ndarray, fs: float, target_hz: float) -> tuple[int, int, float, bool, bool]:
    if target_hz <= 0:
        return 0, 0, 0.0, False, False
    window = min(len(values), max(8, swift_rounded_int(RR_LOCAL_WINDOW_SECONDS * fs)))
    if window < 8:
        return 0, 0, 0.0, False, False
    hop = max(1, swift_rounded_int(RR_LOCAL_HOP_SECONDS * fs))
    total = 0
    agreeing = 0
    for start in range(0, len(values) - window + 1, hop):
        total += 1
        peaks = autocorrelation_peaks(values[start:start + window], fs)
        tol = rr_frequency_tolerance_hz(target_hz)
        if any(abs(freq - target_hz) <= tol for freq, _ in peaks):
            agreeing += 1
    if total == 0 and len(values) >= window:
        total = 1
        peaks = autocorrelation_peaks(values, fs)
        tol = rr_frequency_tolerance_hz(target_hz)
        agreeing = int(any(abs(freq - target_hz) <= tol for freq, _ in peaks))
    fraction = agreeing / total if total else 0.0
    return agreeing, total, fraction, (total > 0 and agreeing * 2 > total), (total >= 2 and agreeing * 3 >= total * 2)


def spectral_verification(strongest_spectral_hz: float | None, target_hz: float) -> str:
    if strongest_spectral_hz is None or target_hz <= 0:
        return "none"
    tol = rr_frequency_tolerance_hz(target_hz)
    if abs(strongest_spectral_hz - target_hz) <= tol:
        return "direct"
    for harmonic in (2.0, 3.0):
        expected = harmonic * target_hz
        htol = max(tol, rr_frequency_tolerance_hz(expected))
        if RR_SEARCH_HZ[0] <= expected <= RR_SEARCH_HZ[1] and abs(strongest_spectral_hz - expected) <= htol:
            return "harmonic"
    return "none"


def spectral_score(support: str) -> float:
    return {"direct": 1.0, "harmonic": 0.75, "none": 0.0}[support]


def peak_to_average_power_ratio(spectrum: Spectrum, peak_power: float) -> float:
    return peak_power / max(float(np.mean(spectrum.power)), np.finfo(float).eps)


def analyze_rr_component(name: str, values: np.ndarray, fs: float) -> ComponentResult:
    grid = frequency_grid(RR_SEARCH_HZ[0], RR_SEARCH_HZ[1], WELCH_FREQUENCY_GRID_POINTS)
    spectrum = welch_spectrum_direct(values, fs, grid)
    spectral_peaks = local_spectral_peaks(spectrum)
    strongest_spectral = max(spectral_peaks, key=lambda p: p[1]) if spectral_peaks else None
    second_power = 0.0
    if strongest_spectral is not None:
        separated = [v for f, v in spectral_peaks if abs(f - strongest_spectral[0]) > RR_PEAK_SEPARATION_HZ]
        second_power = max(separated) if separated else 0.0

    acf_peaks = autocorrelation_peaks(values, fs)
    if not acf_peaks:
        return ComponentResult(name, values, spectrum, None, None if strongest_spectral is None else strongest_spectral[0] * 60,
                               None, 0.0, 0.0, 0, 0, "none", 0.0, 0.0, None, 0.0, False, False)

    strongest_acf = max(acf_peaks, key=lambda p: p[1])
    frequency = strongest_acf[0]
    rate_bpm = frequency * 60.0
    observed_cycles = len(values) / fs * frequency
    agreeing, total, persistence_fraction, has_majority, is_strong = temporal_persistence(values, fs, frequency)
    support = spectral_verification(None if strongest_spectral is None else strongest_spectral[0], frequency)
    reportable = strongest_acf[1] > 0 and observed_cycles >= RR_MINIMUM_OBSERVED_CYCLES and has_majority
    reliable = reportable and is_strong and support != "none"
    quality = float(np.clip(np.mean([np.clip(strongest_acf[1], 0, 1), persistence_fraction, spectral_score(support)]), 0, 1))
    nearest = min(spectral_peaks, key=lambda p: abs(p[0] - frequency)) if spectral_peaks else None
    agreement = None if nearest is None else abs(nearest[0] - frequency) * 60.0
    peak_power = 0.0 if strongest_spectral is None else strongest_spectral[1]
    return ComponentResult(
        name=name,
        filtered=values,
        spectrum=spectrum,
        rate_bpm=rate_bpm if reportable else None,
        welch_rate_bpm=None if strongest_spectral is None else strongest_spectral[0] * 60.0,
        acf_rate_bpm=rate_bpm,
        acf_strength=strongest_acf[1],
        temporal_stability=persistence_fraction,
        local_agreeing_windows=agreeing,
        local_total_windows=total,
        spectral_support=support,
        peak_to_band_power_ratio=peak_to_average_power_ratio(spectrum, peak_power) if strongest_spectral else 0.0,
        first_to_second_peak_ratio=peak_power / max(second_power, np.finfo(float).eps) if strongest_spectral else 0.0,
        domain_agreement_bpm=agreement,
        quality=quality,
        is_reportable=reportable,
        is_reliable=reliable,
    )


def harmonically_related(lhs_bpm: float, rhs_bpm: float) -> bool:
    low, high = min(lhs_bpm, rhs_bpm), max(lhs_bpm, rhs_bpm)
    return low > 0 and abs(high / low - 2.0) <= RR_HARMONIC_RATIO_TOLERANCE


def best_physical_consensus(results: list[ComponentResult]) -> ComponentResult | None:
    reportable = [r for r in results if r.is_reportable and r.rate_bpm is not None]
    best = None
    best_support = 0
    for candidate in reportable:
        support = sum(abs(other.rate_bpm - candidate.rate_bpm) <= rr_rate_tolerance_bpm(candidate.rate_bpm) for other in reportable if other.rate_bpm)
        if support > best_support or (support == best_support and (best is None or candidate.quality > best.quality)):
            best = candidate
            best_support = support
    return best


def estimate_rr(components: dict[str, np.ndarray], fs: float, heart_rate_bpm: float | None):
    allowed_names = ["x", "y", "z", "PC1-band"]
    results = [analyze_rr_component(name, components[name], fs) for name in allowed_names if name in components]
    pca = next((r for r in results if r.name == "PC1-band" and r.is_reportable), None)
    physical = [r for r in results if r.name in ("x", "y", "z")]
    selected = pca or best_physical_consensus(physical)
    if selected is None or selected.rate_bpm is None:
        best = max(results, key=lambda r: r.quality) if results else None
        return {
            "candidate_bpm": None,
            "published_bpm": None,
            "quality": 0.0,
            "reliable": False,
            "selected": "none" if best is None else best.name,
            "status": "uncertain respiratory estimate",
            "component_results": results,
            "filtered": np.array([]) if best is None else best.filtered,
            "spectrum": None if best is None else best.spectrum,
        }

    final_rate = selected.rate_bpm
    agreeing_physical = [r for r in physical if r.rate_bpm is not None and abs(r.rate_bpm - final_rate) <= rr_rate_tolerance_bpm(final_rate)]
    physical_support = len(agreeing_physical)
    alternatives = [r for r in results if r.name != selected.name and r.rate_bpm is not None and abs(r.rate_bpm - final_rate) > rr_rate_tolerance_bpm(final_rate)]
    harmonic_ambiguity = any(harmonically_related(final_rate, r.rate_bpm) and r.is_reliable and r.temporal_stability >= selected.temporal_stability for r in alternatives)
    overlaps_heart = False
    overlaps_subharmonic = False
    if heart_rate_bpm is not None:
        overlaps_heart = abs(heart_rate_bpm - final_rate) <= max(RR_HEART_OVERLAP_BPM, RR_HEART_OVERLAP_FRACTION * max(heart_rate_bpm, final_rate))
        if final_rate >= RR_HEART_SUBHARMONIC_MIN_RATE_BPM:
            half = heart_rate_bpm / 2.0
            overlaps_subharmonic = abs(half - final_rate) <= max(RR_HEART_SUBHARMONIC_BPM, RR_HEART_SUBHARMONIC_FRACTION * max(half, final_rate))
    selected_is_pca = selected.name == "PC1-band"
    reliable = selected.is_reliable and (selected_is_pca or physical_support >= 2) and not harmonic_ambiguity and (not overlaps_heart or physical_support >= 2) and not overlaps_subharmonic
    return {
        "candidate_bpm": final_rate,
        "published_bpm": final_rate if reliable else None,
        "quality": selected.quality,
        "reliable": reliable,
        "selected": selected.name,
        "status": "ok" if reliable else "unreliable respiratory candidate withheld",
        "component_results": results,
        "filtered": selected.filtered,
        "spectrum": selected.spectrum,
    }


def unit_norm(values: np.ndarray) -> np.ndarray | None:
    values = np.asarray(values, dtype=float)
    if len(values) <= 2:
        return None
    centered = remove_mean(values)
    norm = float(np.sqrt(np.dot(centered, centered)))
    if norm <= np.finfo(float).eps:
        return None
    return centered / norm


def pearson(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    if len(a) != len(b) or len(a) <= 1:
        return 0.0
    ma = float(np.mean(a))
    mb = float(np.mean(b))
    da = a - ma
    db = b - mb
    denominator = float(np.sqrt(np.dot(da, da) * np.dot(db, db)))
    return float(np.dot(da, db) / denominator) if denominator > np.finfo(float).eps else 0.0


def elementwise_median(windows: list[np.ndarray]) -> np.ndarray:
    if not windows:
        return np.array([])
    length = len(windows[0])
    if length == 0 or any(len(w) != length for w in windows):
        return np.array([])
    return np.array([float(np.median([w[i] for w in windows])) for i in range(length)])


def median_pairwise_correlation(windows: list[np.ndarray]) -> float:
    if len(windows) < 2:
        return 0.0
    values = []
    for i in range(len(windows) - 1):
        for j in range(i + 1, len(windows)):
            values.append(pearson(windows[i], windows[j]))
    return float(np.median(values)) if values else 0.0


def prominent_peaks_swift(
    values: np.ndarray,
    minimum_distance_samples: int,
    minimum_height: float,
    minimum_prominence: float,
) -> list[tuple[int, float, float]]:
    """Exact decision logic of HeartRateEstimator.prominentPeaks."""
    x = np.asarray(values, dtype=float)
    if len(x) < 3:
        return []
    candidates: list[tuple[int, float, float]] = []
    for index in range(1, len(x) - 1):
        value = float(x[index])
        if value < minimum_height or value < x[index - 1] or value < x[index + 1]:
            continue

        left_minimum = value
        cursor = index - 1
        while True:
            left_minimum = min(left_minimum, float(x[cursor]))
            if x[cursor] > value or cursor == 0:
                break
            cursor -= 1

        right_minimum = value
        cursor = index + 1
        while True:
            right_minimum = min(right_minimum, float(x[cursor]))
            if x[cursor] > value or cursor == len(x) - 1:
                break
            cursor += 1

        prominence = value - max(left_minimum, right_minimum)
        if prominence >= minimum_prominence:
            candidates.append((index, value, prominence))

    ranked = sorted(
        candidates,
        key=lambda p: (-p[1], -p[2]),
    )
    accepted: list[tuple[int, float, float]] = []
    distance = max(1, int(minimum_distance_samples))
    for candidate in ranked:
        if all(abs(existing[0] - candidate[0]) >= distance for existing in accepted):
            accepted.append(candidate)
    return sorted(accepted, key=lambda p: p[0])


def automatic_template_selection(x: np.ndarray, fs: float):
    requested = max(1, swift_rounded_int(HEART_TEMPLATE_WINDOW_SECONDS * fs))
    minimum = max(1, swift_rounded_int(HEART_TEMPLATE_MINIMUM_WINDOW_SECONDS * fs))
    if len(x) < minimum:
        return None
    pre = max(1, swift_rounded_int(HEART_TEMPLATE_PRE_SECONDS * fs))
    post = max(1, swift_rounded_int(HEART_TEMPLATE_POST_SECONDS * fs))
    start = 0
    while start < len(x):
        end = min(start + requested, len(x))
        if end - start < minimum:
            break
        segment = x[start:end]

        fourth_power = segment ** 4
        envelope = lowpass(fourth_power, fs, HEART_TEMPLATE_ENVELOPE_LOWPASS_HZ, HEART_TEMPLATE_ENVELOPE_LOWPASS_ORDER)
        maximum = float(np.max(np.abs(envelope))) if len(envelope) else 0.0
        if maximum <= np.finfo(float).eps:
            start += requested
            continue
        envelope = envelope / maximum

        preliminary = [
            p[0] for p in prominent_peaks_swift(
                envelope,
                minimum_distance_samples=1,
                minimum_height=-np.inf,
                minimum_prominence=HEART_TEMPLATE_ENVELOPE_PEAK_PROMINENCE,
            )
        ]
        if len(preliminary) < HEART_TEMPLATE_MINIMUM_PEAKS:
            start += requested
            continue

        preliminary_ibi = np.diff(preliminary) / fs
        ibi_mean = float(np.mean(preliminary_ibi)) if len(preliminary_ibi) else 0.0
        mad_mean = float(np.mean(np.abs(preliminary_ibi - ibi_mean))) if len(preliminary_ibi) else float("inf")
        variability_limit = HEART_TEMPLATE_MAXIMUM_IBI_MAD_SECONDS + 1.0 / fs
        if mad_mean > variability_limit:
            start += requested
            continue

        candidate_windows: list[np.ndarray] = []
        for peak in preliminary:
            lower = peak - pre
            upper = peak + post
            if lower < 0 or upper >= len(segment):
                continue
            window = unit_norm(segment[lower:upper + 1])
            if window is not None:
                candidate_windows.append(window)
        if len(candidate_windows) < HEART_TEMPLATE_MINIMUM_PEAKS:
            start += requested
            continue

        best_index = None
        best_representativeness = -np.inf
        for index in range(len(candidate_windows)):
            correlations = [
                pearson(candidate_windows[index], candidate_windows[other])
                for other in range(len(candidate_windows)) if other != index
            ]
            if not correlations:
                continue
            average = float(np.mean(correlations))
            standard_deviation = float(np.std(correlations))
            representativeness = average / max(standard_deviation, 1e-6)
            if representativeness > best_representativeness:
                best_representativeness = representativeness
                best_index = index

        if best_index is not None:
            medoid = candidate_windows[best_index]
            clustered = [
                w for w in candidate_windows
                if pearson(medoid, w) >= HEART_TEMPLATE_CLUSTER_MINIMUM_CORRELATION
            ]
            if len(clustered) < 3:
                clustered = sorted(candidate_windows, key=lambda w: pearson(medoid, w), reverse=True)[:min(5, len(candidate_windows))]
            final_template = unit_norm(elementwise_median(clustered))
            if final_template is not None:
                return final_template, pre, mad_mean
        start += requested
    return None


def normalized_cross_correlation(x: np.ndarray, template: np.ndarray) -> np.ndarray:
    n = len(x)
    length = len(template)
    out = np.zeros(n, dtype=float)
    if n < length or length <= 1:
        return out
    centered_template = template - float(np.mean(template))
    template_norm = float(np.sqrt(np.dot(centered_template, centered_template)))
    if template_norm <= np.finfo(float).eps:
        return out

    # Same Pearson/NCC formula as Swift; vectorised only for speed.
    ones = np.ones(length, dtype=float)
    sums = np.convolve(x, ones, mode="valid")
    sums_sq = np.convolve(x * x, ones, mode="valid")
    local_energy = np.maximum(sums_sq - sums * sums / float(length), 0.0)
    numerator = np.correlate(x, centered_template, mode="valid")
    denominator = template_norm * np.sqrt(local_energy)
    valid = np.zeros_like(numerator, dtype=float)
    mask = denominator > np.finfo(float).eps
    valid[mask] = numerator[mask] / denominator[mask]
    out[:len(valid)] = valid
    return out


def odd_even_morphology(signal_values: np.ndarray, beat_samples: np.ndarray, fs: float):
    pre = max(1, swift_rounded_int(0.06 * fs))
    post = max(2, swift_rounded_int(0.16 * fs))
    even: list[np.ndarray] = []
    odd: list[np.ndarray] = []
    for index, beat in enumerate(beat_samples):
        lower = int(beat) - pre
        upper = int(beat) + post
        if lower < 0 or upper >= len(signal_values):
            continue
        window = unit_norm(signal_values[lower:upper + 1])
        if window is None:
            continue
        (even if index % 2 == 0 else odd).append(window)
    if len(even) < 2 or len(odd) < 2:
        return 0.0, 0.0, 0.0
    even_within = median_pairwise_correlation(even)
    odd_within = median_pairwise_correlation(odd)
    cross = [pearson(e, o) for e in even for o in odd]
    return even_within, odd_within, float(np.median(cross)) if cross else 0.0


def resolve_alternating_mechanical_complexes(
    signal_values: np.ndarray,
    beat_samples: np.ndarray,
    correlations: np.ndarray,
    fs: float,
):
    beat_samples = np.asarray(beat_samples, dtype=int)
    correlations = np.asarray(correlations, dtype=float)
    if len(beat_samples) < 8 or len(beat_samples) != len(correlations):
        return beat_samples, correlations

    intervals = np.diff(beat_samples) / fs
    if len(intervals) < 6:
        return beat_samples, correlations
    even_intervals = intervals[0::2]
    odd_intervals = intervals[1::2]
    if len(even_intervals) == 0 or len(odd_intervals) == 0:
        return beat_samples, correlations

    even_median = float(np.median(even_intervals))
    odd_median = float(np.median(odd_intervals))
    interval_center = max((even_median + odd_median) / 2.0, np.finfo(float).eps)
    relative_alternation = abs(even_median - odd_median) / interval_center

    raw_cv = robust_cv(intervals)
    paired_intervals = (beat_samples[2:] - beat_samples[:-2]) / fs
    paired_median = float(np.median(paired_intervals))
    paired_cv = robust_cv(paired_intervals)
    paired_rate = 60.0 / paired_median if paired_median > 0 else 0.0
    even_within, odd_within, cross_parity = odd_even_morphology(signal_values, beat_samples, fs)

    rate_in_range = HR_RANGE_BPM[0] <= paired_rate <= HR_RANGE_BPM[1]
    timing_supports = (
        relative_alternation >= HEART_ALTERNATING_INTERVAL_MINIMUM_RELATIVE_DIFFERENCE
        and paired_cv <= HEART_ALTERNATING_PAIR_MAXIMUM_ROBUST_CV
        and paired_cv <= HEART_ALTERNATING_PAIR_DISPERSION_IMPROVEMENT_FACTOR * max(raw_cv, 1e-6)
    )
    morphology_supports = (
        even_within >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and odd_within >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and cross_parity < min(even_within, odd_within)
    )
    if not (rate_in_range and timing_supports and morphology_supports):
        return beat_samples, correlations

    even_correlations = correlations[0::2]
    odd_correlations = correlations[1::2]
    keep_even = float(np.median(even_correlations)) >= float(np.median(odd_correlations))
    kept = np.arange(0 if keep_even else 1, len(beat_samples), 2, dtype=int)
    return beat_samples[kept], correlations[kept]


def has_systematic_midpoint_matches(
    ncc: np.ndarray,
    beat_samples: np.ndarray,
    accepted_correlations: np.ndarray,
    peak_offset_samples: int,
    fs: float,
    current_rate_bpm: float,
) -> bool:
    if len(beat_samples) < 7 or current_rate_bpm * 2.0 > HR_RANGE_BPM[1] or len(accepted_correlations) == 0:
        return False

    accepted_median = float(np.median(accepted_correlations))
    minimum_midpoint_correlation = max(
        HEART_NCC_MINIMUM_CORRELATION,
        HEART_MIDPOINT_CORRELATION_FRACTION_OF_ACCEPTED_MEDIAN * accepted_median,
    )
    supported_midpoints: list[int] = []
    for index in range(len(beat_samples) - 1):
        left = int(beat_samples[index])
        right = int(beat_samples[index + 1])
        ibi = right - left
        if ibi <= 2:
            continue
        midpoint = (left + right) // 2
        radius = max(1, swift_rounded_int(HEART_MIDPOINT_SEARCH_FRACTION_OF_IBI * float(ibi)))
        expected_ncc_index = midpoint - peak_offset_samples
        lower = max(0, expected_ncc_index - radius)
        upper = min(len(ncc) - 1, expected_ncc_index + radius)
        if lower > upper:
            continue
        local = ncc[lower:upper + 1]
        relative = int(np.argmax(local))
        best_index = lower + relative
        best_value = float(ncc[best_index])
        if best_value >= minimum_midpoint_correlation:
            supported_midpoints.append(best_index + peak_offset_samples)

    support_fraction = len(supported_midpoints) / max(len(beat_samples) - 1, 1)
    if support_fraction < HEART_MIDPOINT_MINIMUM_SUPPORT_FRACTION:
        return False
    expanded = np.array(sorted(set(map(int, beat_samples)) | set(supported_midpoints)), dtype=int)
    if len(expanded) <= len(beat_samples):
        return False
    expanded_intervals = np.diff(expanded) / fs
    expanded_median = float(np.median(expanded_intervals))
    if expanded_median <= 0:
        return False
    expanded_rate = 60.0 / expanded_median
    expanded_cv = robust_cv(expanded_intervals)
    return HR_RANGE_BPM[0] <= expanded_rate <= HR_RANGE_BPM[1] and expanded_cv <= HEART_MIDPOINT_EXPANDED_MAXIMUM_ROBUST_CV


def interval_diagnostics(beat_samples: np.ndarray, fs: float):
    if len(beat_samples) < 2:
        return np.array([]), 0.0, float("inf")
    intervals = np.diff(beat_samples) / fs
    sample_tolerance = 1.0 / fs
    minimum_ibi = 60.0 / HR_RANGE_BPM[1] - sample_tolerance
    maximum_ibi = 60.0 / HR_RANGE_BPM[0] + sample_tolerance
    valid = intervals[(intervals >= minimum_ibi) & (intervals <= maximum_ibi)]
    return valid, len(valid) / max(len(intervals), 1), robust_cv(valid)


def robust_central_interval(values: np.ndarray, fs: float) -> float:
    if len(values) == 0:
        return 0.0
    center = float(np.median(values))
    robust_scale = max(median_abs_deviation(values), 1.0 / max(fs, np.finfo(float).eps))
    retained = values[np.abs(values - center) <= 3.0 * robust_scale]
    return float(np.mean(retained)) if len(retained) else center


def analyze_heart_axis(values: np.ndarray, fs: float) -> HeartAnalysis:
    if len(values) < MINIMUM_SAMPLE_COUNT or fs <= 0:
        return HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), np.array([]), 0.0, "template/NCC")
    centered = remove_mean(values)
    scale = max(median_abs_deviation(centered), np.finfo(float).eps)
    x = centered / scale
    selection = automatic_template_selection(x, fs)
    if selection is None:
        return HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), x, 0.0, "template/NCC")

    template, peak_offset, _template_mad = selection
    ncc = normalized_cross_correlation(x, template)
    physiological_minimum_ibi = 60.0 / HR_RANGE_BPM[1]
    minimum_peak_distance_seconds = HEART_NCC_MINIMUM_PEAK_DISTANCE_FRACTION_OF_MINIMUM_IBI * physiological_minimum_ibi
    minimum_peak_distance_samples = max(1, swift_rounded_int(minimum_peak_distance_seconds * fs))
    raw_peaks = prominent_peaks_swift(
        ncc,
        minimum_distance_samples=minimum_peak_distance_samples,
        minimum_height=HEART_NCC_MINIMUM_CORRELATION,
        minimum_prominence=HEART_NCC_MINIMUM_PROMINENCE,
    )
    if len(raw_peaks) < HEART_MINIMUM_BEAT_COUNT:
        return HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), x, 0.0, "template/NCC")

    raw_peak_indices = np.array([p[0] for p in raw_peaks], dtype=int)
    raw_beat_samples = np.minimum(len(x) - 1, raw_peak_indices + peak_offset)
    raw_correlations = np.array([p[1] for p in raw_peaks], dtype=float)
    beat_samples, correlations = resolve_alternating_mechanical_complexes(x, raw_beat_samples, raw_correlations, fs)
    if len(beat_samples) < HEART_MINIMUM_BEAT_COUNT:
        return HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), x, 0.0, "template/NCC")

    valid_intervals, valid_fraction, cv = interval_diagnostics(beat_samples, fs)
    if len(valid_intervals) < HEART_MINIMUM_BEAT_COUNT - 1:
        return HeartAnalysis(None, None, len(beat_samples), None, None, 0.0, False, beat_samples / fs, x, valid_fraction, "template/NCC")

    representative_ibi = robust_central_interval(valid_intervals, fs)
    if representative_ibi <= 0:
        return HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), x, 0.0, "template/NCC")
    raw_rate = 60.0 / representative_ibi
    observed_span = max((beat_samples[-1] - beat_samples[0]) / fs, 1.0)
    boundary_resolution_bpm = 60.0 / observed_span
    in_range = HR_RANGE_BPM[0] - boundary_resolution_bpm <= raw_rate <= HR_RANGE_BPM[1] + boundary_resolution_bpm
    rate = min(max(raw_rate, HR_RANGE_BPM[0]), HR_RANGE_BPM[1])

    midpoint_ambiguity = has_systematic_midpoint_matches(
        ncc,
        beat_samples,
        correlations,
        peak_offset,
        fs,
        rate,
    )
    median_correlation = float(np.median(correlations))
    regularity = float(np.clip(1.0 - cv / max(HEART_MAXIMUM_IBI_VARIABILITY, np.finfo(float).eps), 0.0, 1.0))
    quality = float(np.clip(0.45 * median_correlation + 0.30 * valid_fraction + 0.25 * regularity, 0.0, 1.0))
    reliable = (
        in_range
        and not midpoint_ambiguity
        and valid_fraction >= HEART_MINIMUM_VALID_INTERVAL_FRACTION
        and cv <= HEART_MAXIMUM_IBI_VARIABILITY
        and median_correlation >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and quality >= HEART_RELIABLE_QUALITY_THRESHOLD
    )
    return HeartAnalysis(
        rate if reliable else None,
        raw_rate,
        len(beat_samples),
        cv,
        median_correlation,
        quality,
        reliable,
        beat_samples / fs,
        x,
        valid_fraction,
        "template/NCC",
    )


def moving_rms_swift(values: np.ndarray, samples: int) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    samples = max(1, int(samples))
    prefix = np.zeros(len(values) + 1, dtype=float)
    prefix[1:] = np.cumsum(values * values)
    half = samples // 2
    out = np.zeros(len(values), dtype=float)
    for index in range(len(values)):
        lower = max(0, index - half)
        upper = min(len(values), lower + samples)
        count = max(1, upper - lower)
        mean_square = (prefix[upper] - prefix[lower]) / float(count)
        out[index] = np.sqrt(max(0.0, mean_square))
    return out


def moving_rms(values: np.ndarray, samples: int) -> np.ndarray:
    # Kept as the plotting/helper name; algorithmic HR code uses the Swift edge convention.
    return moving_rms_swift(values, samples)


def estimate_heart_acf_period_from_envelope(envelope: np.ndarray, fs: float):
    values = np.asarray(envelope, dtype=float)
    if len(values) < MINIMUM_SAMPLE_COUNT:
        return None
    centered = remove_mean(values)
    energy = float(np.dot(centered, centered))
    if energy <= np.finfo(float).eps:
        return None
    min_lag = max(1, swift_rounded_int(60.0 * fs / HR_RANGE_BPM[1]))
    max_lag = min(len(centered) - 2, swift_rounded_int(60.0 * fs / HR_RANGE_BPM[0]))
    if min_lag >= max_lag:
        return None

    acf = np.zeros(max_lag + 2, dtype=float)
    for lag in range(max(1, min_lag - 1), min(len(centered) - 1, max_lag + 1) + 1):
        acf[lag] = float(np.dot(centered[:len(centered) - lag], centered[lag:]) / energy)

    peaks: list[tuple[int, float]] = []
    for lag in range(min_lag, max_lag + 1):
        c = float(acf[lag])
        if c > 0 and c >= acf[lag - 1] and c >= acf[lag + 1]:
            peaks.append((lag, c))
    if not peaks:
        return None
    strongest = max(p[1] for p in peaks)
    minimum_strength = max(HEART_ACF_MINIMUM_STRENGTH, HEART_ACF_SIGNIFICANT_PEAK_FRACTION * strongest)
    eligible = [p for p in peaks if p[1] >= minimum_strength]
    if not eligible:
        return None
    selected = min(eligible, key=lambda p: p[0])
    lag = selected[0]
    refined_lag = float(lag)
    denominator = acf[lag - 1] - 2.0 * acf[lag] + acf[lag + 1]
    if abs(denominator) > np.finfo(float).eps:
        refined_lag += 0.5 * (acf[lag - 1] - acf[lag + 1]) / denominator
    if refined_lag <= 0:
        return None
    rate = 60.0 * fs / refined_lag
    if not (HR_RANGE_BPM[0] <= rate <= HR_RANGE_BPM[1]):
        return None
    return rate, selected[1]


def heart_axis_periodicity(values: np.ndarray, fs: float):
    if len(values) == 0 or fs <= 0:
        return None
    window_samples = max(1, swift_rounded_int(HEART_RMS_ENVELOPE_WINDOW_SECONDS * fs))
    rms = moving_rms_swift(values, window_samples)
    envelope = remove_mean(rms)
    global_period = estimate_heart_acf_period_from_envelope(envelope, fs)
    if global_period is None:
        return None

    local_window = min(
        len(envelope),
        max(MINIMUM_SAMPLE_COUNT, swift_rounded_int(HEART_ACF_LOCAL_WINDOW_SECONDS * fs)),
    )
    local_hop = max(1, swift_rounded_int(HEART_ACF_LOCAL_HOP_SECONDS * fs))
    local_rates: list[float] = []
    if local_window <= len(envelope):
        start = 0
        while start + local_window <= len(envelope):
            local = estimate_heart_acf_period_from_envelope(envelope[start:start + local_window], fs)
            if local is not None:
                local_rates.append(local[0])
            start += local_hop
    agreeing = sum(rates_agree(rate, global_period[0]) for rate in local_rates)
    local_agreement = agreeing / len(local_rates) if local_rates else 0.0
    return global_period[0], global_period[1], local_agreement, len(local_rates)


def rates_agree(lhs: float, rhs: float) -> bool:
    tolerance = max(HEART_ACF_AGREEMENT_BPM, HEART_ACF_AGREEMENT_FRACTION * max(lhs, rhs))
    return abs(lhs - rhs) <= tolerance


def heart_harmonically_related(lhs: float, rhs: float) -> bool:
    low = min(lhs, rhs)
    high = max(lhs, rhs)
    return low > 0 and abs(high / low - 2.0) <= HEART_HARMONIC_RATIO_TOLERANCE


def select_best_physical_axis(analyses: list[tuple[str, HeartAnalysis]]):
    if not analyses:
        return "none", HeartAnalysis(None, None, 0, None, None, 0.0, False, np.array([]), np.array([]), 0.0, "template/NCC")
    physical = [item for item in analyses if item[0] in ("x", "y", "z")]
    pool = physical if physical else analyses

    def key(item):
        a = item[1]
        return (
            1 if a.is_reliable else 0,
            a.valid_interval_fraction,
            -(a.ibi_cv if a.ibi_cv is not None else np.inf),
            a.median_correlation if a.median_correlation is not None else -1.0,
            a.quality,
        )
    return max(pool, key=key)


def alternating_morphology_ambiguity(signal_values: np.ndarray, beat_times: np.ndarray, fs: float) -> bool:
    if len(beat_times) < 8:
        return False
    beat_samples = np.array([swift_rounded_int(float(t) * fs) for t in beat_times], dtype=int)
    intervals = np.diff(beat_samples) / fs
    if len(intervals) == 0:
        return False
    center = float(np.median(intervals))
    if center <= 0:
        return False
    interval_cv = median_abs_deviation(intervals) / center
    if interval_cv > HEART_AMBIGUOUS_UNIFORM_INTERVAL_CV:
        return False

    pre = max(1, swift_rounded_int(0.06 * fs))
    post = max(2, swift_rounded_int(0.16 * fs))
    even: list[np.ndarray] = []
    odd: list[np.ndarray] = []
    for index, beat in enumerate(beat_samples):
        lower = beat - pre
        upper = beat + post
        if lower < 0 or upper >= len(signal_values):
            continue
        window = unit_norm(signal_values[lower:upper + 1])
        if window is None:
            continue
        (even if index % 2 == 0 else odd).append(window)
    if len(even) < 3 or len(odd) < 3:
        return False
    even_within = median_pairwise_correlation(even)
    odd_within = median_pairwise_correlation(odd)
    cross = [pearson(e, o) for e in even for o in odd]
    cross_median = float(np.median(cross)) if cross else 0.0
    return (
        even_within >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and odd_within >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and cross_median < min(even_within, odd_within)
    )


def _confirmed_analysis(analysis: HeartAnalysis, rate: float, acf_strength: float, supporting_axes: int) -> HeartAnalysis:
    correlation = analysis.median_correlation or 0.0
    enough_beat_evidence = (
        analysis.valid_interval_fraction >= HEART_CONFIRMED_MINIMUM_VALID_INTERVAL_FRACTION
        and correlation >= HEART_MINIMUM_TEMPLATE_CORRELATION
        and analysis.detected_beat_count >= HEART_MINIMUM_BEAT_COUNT
    )
    enough_periodicity_evidence = acf_strength >= HEART_ACF_MINIMUM_STRENGTH and supporting_axes >= HEART_ACF_MINIMUM_SUPPORTING_AXES
    reliable = analysis.is_reliable or (enough_beat_evidence and enough_periodicity_evidence)
    quality = float(np.clip((analysis.valid_interval_fraction + correlation + min(1.0, acf_strength)) / 3.0, 0.0, 1.0))
    published_rate = rate if reliable else None
    return HeartAnalysis(published_rate, rate, analysis.detected_beat_count, analysis.ibi_cv, analysis.median_correlation,
                         quality, reliable, analysis.beat_times_s, analysis.normalized_signal,
                         analysis.valid_interval_fraction, "template/NCC")


def _periodicity_only_analysis(base: HeartAnalysis, rate: float, acf_strength: float, local_agreement: float) -> HeartAnalysis:
    quality = float(np.clip(min(acf_strength, local_agreement), 0.0, 1.0))
    return HeartAnalysis(rate, rate, 0, None, None, quality, True, np.array([]), base.normalized_signal, 0.0, "ACF fallback")


def _cautious_copy(analysis: HeartAnalysis) -> HeartAnalysis:
    return HeartAnalysis(None, analysis.baseline_rate_bpm, analysis.detected_beat_count, analysis.ibi_cv,
                         analysis.median_correlation, analysis.quality, False, analysis.beat_times_s,
                         analysis.normalized_signal, analysis.valid_interval_fraction, analysis.method)


def estimate_hr(heart_components: dict[str, np.ndarray], fs: float) -> HeartAnalysis:
    axes = [(name, heart_components[name]) for name in ("x", "y", "z") if name in heart_components]
    analyses = [(name, analyze_heart_axis(values, fs)) for name, values in axes]
    template_name, template_default = select_best_physical_axis(analyses)

    periodicities = []
    for name, values in axes:
        periodicity = heart_axis_periodicity(values, fs)
        if periodicity is not None:
            periodicities.append((name, periodicity[0], periodicity[1], periodicity[2], periodicity[3]))

    if not periodicities:
        return template_default

    stable_periodicities = [
        p for p in periodicities
        if p[4] > 0 and p[3] >= HEART_ACF_MINIMUM_LOCAL_AGREEMENT_FRACTION
    ]

    supported = []
    for name, analysis in analyses:
        if analysis.baseline_rate_bpm is None:
            continue
        supporting_axes = [p for p in periodicities if rates_agree(analysis.baseline_rate_bpm, p[1])]
        if supporting_axes:
            supported.append((name, analysis, analysis.baseline_rate_bpm, supporting_axes))

    if supported:
        # Exact priority from HeartRateReconciler.select.
        supported.sort(key=lambda item: (
            -len(item[3]),
            -(1 if item[1].is_reliable else 0),
            -item[1].valid_interval_fraction,
            -(item[1].median_correlation or 0.0),
            item[1].ibi_cv if item[1].ibi_cv is not None else np.inf,
        ))
        chosen_name, chosen, chosen_rate, support = supported[0]
        mean_strength = float(np.mean([p[2] for p in support]))
        mean_rate = float(np.median([p[1] for p in support]))

        if chosen_rate / 2.0 >= HR_RANGE_BPM[0]:
            component = next((values for name, values in axes if name == chosen_name), None)
            if component is not None and alternating_morphology_ambiguity(component, chosen.beat_times_s, fs):
                return _cautious_copy(chosen)
        return _confirmed_analysis(chosen, chosen_rate, mean_strength, len(support))

    # Build ACF clusters in insertion order, exactly like Swift.
    clusters: list[list[tuple]] = []
    for value in stable_periodicities:
        placed = False
        for cluster in clusters:
            center = float(np.median([x[1] for x in cluster]))
            if rates_agree(center, value[1]):
                cluster.append(value)
                placed = True
                break
        if not placed:
            clusters.append([value])
    clusters.sort(key=lambda c: (
        -len(c),
        -float(np.mean([x[3] for x in c])),
        -float(np.mean([x[2] for x in c])),
    ))
    best_stable_acf = clusters[0] if clusters else None

    has_reliable_template = any(a.is_reliable for _, a in analyses)
    if not has_reliable_template and best_stable_acf is not None:
        center = float(np.median([x[1] for x in best_stable_acf]))
        mean_strength = float(np.mean([x[2] for x in best_stable_acf]))
        mean_local = float(np.mean([x[3] for x in best_stable_acf]))
        if (len(best_stable_acf) >= HEART_ACF_MINIMUM_SUPPORTING_AXES
                and mean_strength >= HEART_ACF_MINIMUM_STRENGTH
                and mean_local >= HEART_ACF_MINIMUM_LOCAL_AGREEMENT_FRACTION):
            representative = max(best_stable_acf, key=lambda p: p[2] * p[3])[0]
            base = next((a for name, a in analyses if name == representative), template_default)
            return _periodicity_only_analysis(base, center, mean_strength, mean_local)

    if template_default.baseline_rate_bpm is not None and best_stable_acf is not None:
        center = float(np.median([x[1] for x in best_stable_acf]))
        if heart_harmonically_related(template_default.baseline_rate_bpm, center):
            return _cautious_copy(template_default)

    if template_default.baseline_rate_bpm is not None:
        return _cautious_copy(template_default)
    return template_default


def process_file(path: Path):
    time, axes = load_csv(path)
    time, axes, fs, resampled = uniform_sampling(time, axes)
    time, axes = preprocess(time, axes, fs)
    heart_components, _ = band_limited_candidates(axes, fs, HR_FILTER_HZ, HEART_FILTER_ORDER)
    heart = estimate_hr(heart_components, fs)
    respiration_components, _ = band_limited_candidates(axes, fs, RR_FILTER_HZ, RESPIRATION_FILTER_ORDER)
    respiration = estimate_rr(respiration_components, fs, heart.rate_bpm if heart.is_reliable else None)
    result = {
        "file": path.name,
        "algorithm_version": ALGORITHM_VERSION,
        "duration_s": round(float(time[-1] - time[0]), 2),
        "fs_hz": round(fs, 2),
        "resampled": resampled,
        "respiratory_rate": "" if respiration["published_bpm"] is None else round(respiration["published_bpm"], 1),
        "rr_candidate": "" if respiration["candidate_bpm"] is None else round(respiration["candidate_bpm"], 1),
        "rr_reliable": respiration["reliable"],
        "rr_quality": round(respiration["quality"], 2),
        "rr_component": respiration["selected"],
        "heart_rate": "" if heart.rate_bpm is None else round(heart.rate_bpm, 1),
        "hr_baseline": "" if heart.baseline_rate_bpm is None else round(heart.baseline_rate_bpm, 1),
        "hr_reliable": heart.is_reliable,
        "hr_quality": round(heart.quality, 2),
        "hr_method": heart.method,
        "status": respiration["status"],
    }
    return result, time, axes, fs, respiration, heart


def transient_mask(axes: np.ndarray, fs: float):
    energy = np.linalg.norm(axes, axis=1)
    smooth = moving_rms(energy, round(0.20 * fs))
    med = float(np.median(smooth))
    mad = float(np.median(np.abs(smooth - med)))
    threshold = med + 5.0 * max(1.4826 * mad, 1e-12)
    mask = smooth > threshold
    width = max(1, int(round(0.30 * fs)))
    return np.convolve(mask.astype(int), np.ones(width, dtype=int), mode="same") > 0


def shade_mask(ax, time: np.ndarray, mask: np.ndarray, label="high-energy transient"):
    if not np.any(mask):
        return
    changes = np.diff(np.r_[False, mask, False].astype(int))
    starts = np.flatnonzero(changes == 1)
    ends = np.flatnonzero(changes == -1) - 1
    first = True
    for start, end in zip(starts, ends):
        ax.axvspan(time[start], time[end], alpha=0.10, label=label if first else None)
        first = False


def quality_text(value: float) -> str:
    if value >= 0.65:
        return "high"
    if value >= 0.45:
        return "medium"
    return "low"


def plot_recording(path: Path, result: dict, time: np.ndarray, axes: np.ndarray, fs: float, respiration: dict, heart: HeartAnalysis, output_dir: Path):
    t = time - time[0]
    motion = transient_mask(axes, fs)
    rr_signal = respiration["filtered"] if len(respiration["filtered"]) else np.zeros_like(t)
    rr_acf = acf_array(rr_signal)
    rr_lags = np.arange(len(rr_acf)) / fs
    spectrum = respiration["spectrum"]
    if spectrum is None:
        spectrum = Spectrum(frequency_grid(RR_SEARCH_HZ[0], RR_SEARCH_HZ[1], WELCH_FREQUENCY_GRID_POINTS), np.zeros(WELCH_FREQUENCY_GRID_POINTS))
    heart_axis = heart.normalized_signal if len(heart.normalized_signal) else band_limited_candidates(axes, fs, HR_FILTER_HZ, HEART_FILTER_ORDER)[0]["x"]
    heart_env = moving_rms(heart_axis, round(HEART_RMS_ENVELOPE_WINDOW_SECONDS * fs))
    heart_acf = acf_array(signal.detrend(heart_env))
    heart_lags = np.arange(len(heart_acf)) / fs

    fig = plt.figure(figsize=(12, 12))
    grid = fig.add_gridspec(4, 2, height_ratios=[1.15, 1.0, 1.0, 1.0])
    ax_acc = fig.add_subplot(grid[0, :])
    ax_rr = fig.add_subplot(grid[1, :])
    ax_rr_acf = fig.add_subplot(grid[2, 0])
    ax_rr_psd = fig.add_subplot(grid[2, 1])
    ax_hr = fig.add_subplot(grid[3, 0])
    ax_hr_acf = fig.add_subplot(grid[3, 1])

    for i, label in enumerate(("X", "Y", "Z")):
        ax_acc.plot(t, axes[:, i], linewidth=0.8, label=label)
    shade_mask(ax_acc, t, motion)
    ax_acc.set_title("Preprocessed accelerometer signal")
    ax_acc.set_ylabel("Acceleration")
    ax_acc.set_xlabel("Time [s]")
    ax_acc.legend(ncol=4, fontsize=8, loc="upper right")
    ax_acc.grid(alpha=0.20)

    ax_rr.plot(t, rr_signal, linewidth=1.1)
    shade_mask(ax_rr, t, motion)
    rr_pub = result["respiratory_rate"]
    rr_cand = result["rr_candidate"]
    if rr_pub != "":
        rr_title = f"RR = {rr_pub} breaths/min | reliable"
    elif rr_cand != "":
        rr_title = f"RR candidate = {rr_cand} breaths/min | withheld by reliability gate"
    else:
        rr_title = "RR not estimated"
    ax_rr.set_title(f"Respiratory component  |  {rr_title}")
    ax_rr.set_ylabel("Amplitude")
    ax_rr.set_xlabel("Time [s]")
    ax_rr.grid(alpha=0.20)

    rr_mask = (rr_lags >= 1.0 / RR_SEARCH_HZ[1]) & (rr_lags <= 1.0 / RR_SEARCH_HZ[0])
    ax_rr_acf.plot(rr_lags[rr_mask], rr_acf[rr_mask], linewidth=1.2)
    if rr_cand != "":
        ax_rr_acf.axvline(60.0 / float(rr_cand), linestyle="--", label=f"ACF candidate: {60.0 / float(rr_cand):.2f} s")
    ax_rr_acf.set_title("Respiratory autocorrelation (primary period)")
    ax_rr_acf.set_xlabel("Lag [s]")
    ax_rr_acf.set_ylabel("Normalized ACF")
    ax_rr_acf.grid(alpha=0.20)
    if ax_rr_acf.get_legend_handles_labels()[0]:
        ax_rr_acf.legend(fontsize=8)

    ax_rr_psd.plot(spectrum.frequencies_hz, spectrum.power, linewidth=1.2, label="Welch PSD")
    peak = spectrum.peak(*RR_SEARCH_HZ)
    if peak:
        ax_rr_psd.axvline(peak[0], linestyle=":", label=f"Max PSD: {60*peak[0]:.1f} breaths/min")
    if rr_cand != "":
        ax_rr_psd.axvline(float(rr_cand) / 60.0, linestyle="--", label=f"ACF candidate: {rr_cand}")
    ax_rr_psd.set_title("Welch PSD (verification / harmonics)")
    ax_rr_psd.set_xlabel("Frequency [Hz]")
    ax_rr_psd.set_ylabel("PSD")
    ax_rr_psd.grid(alpha=0.20)
    ax_rr_psd.legend(fontsize=8)

    zoom_s = min(15.0, float(t[-1]))
    zoom = t <= zoom_s
    ax_hr.plot(t[zoom], heart_axis[zoom], linewidth=0.8, label="heart-band axis")
    if len(heart.beat_times_s):
        for beat in heart.beat_times_s:
            if beat <= zoom_s:
                ax_hr.axvline(beat, alpha=0.20, linewidth=0.9)
    hr_value = result["heart_rate"]
    hr_title = f"HR = {hr_value} bpm" if hr_value != "" else "HR not estimated"
    ax_hr.set_title(f"Cardiac component and detected beats - {zoom_s:.0f} s zoom  |  {hr_title}")
    ax_hr.set_xlabel("Time [s]")
    ax_hr.set_ylabel("Standardized amplitude")
    ax_hr.grid(alpha=0.20)
    ax_hr.legend(fontsize=8)

    hm = (heart_lags >= 60.0 / HR_RANGE_BPM[1]) & (heart_lags <= 60.0 / HR_RANGE_BPM[0])
    ax_hr_acf.plot(heart_lags[hm], heart_acf[hm], linewidth=1.2)
    if result["hr_baseline"] != "":
        ax_hr_acf.axvline(60.0 / float(result["hr_baseline"]), linestyle="--", label=f"IBI-derived HR: {result['hr_baseline']}")
    ax_hr_acf.set_title("Cardiac envelope ACF (consistency only)")
    ax_hr_acf.set_xlabel("Lag [s]")
    ax_hr_acf.set_ylabel("Normalized ACF")
    ax_hr_acf.grid(alpha=0.20)
    if ax_hr_acf.get_legend_handles_labels()[0]:
        ax_hr_acf.legend(fontsize=8)

    rr_display = result["respiratory_rate"] or "withheld"
    hr_display = result["heart_rate"] or "---"
    subtitle = (
        f"v{ALGORITHM_VERSION} | duration {result['duration_s']} s | fs {result['fs_hz']} Hz | "
        f"RR {rr_display} (candidate {rr_cand or '---'}, Q={result['rr_quality']}, {quality_text(result['rr_quality'])}) | "
        f"HR {hr_display} (Q={result['hr_quality']}, {quality_text(result['hr_quality'])}; {result['hr_method']})"
    )
    fig.suptitle(path.name, fontsize=16, y=0.995)
    fig.text(0.5, 0.968, subtitle, ha="center", va="top", fontsize=9)
    fig.tight_layout(rect=[0, 0, 1, 0.955])
    fig.savefig(output_dir / f"{path.stem}.png", dpi=170)
    plt.close(fig)


def main():
    base_dir = Path(__file__).resolve().parent
    data_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else base_dir / "data"
    files = sorted(data_dir.glob("*.csv"))
    if not files:
        raise SystemExit(f"No CSV files found in: {data_dir}")

    output_dir = base_dir / "results"
    output_dir.mkdir(exist_ok=True)

    processed = 0
    for path in files:
        try:
            result, time, axes, fs, respiration, heart = process_file(path)
            plot_recording(path, result, time, axes, fs, respiration, heart, output_dir)
            processed += 1
            print(
                f"{path.name}: RR={result['respiratory_rate'] or 'withheld'} breaths/min "
                f"(candidate {result['rr_candidate'] or '---'}), "
                f"HR={result['heart_rate'] or '---'} bpm, fs={result['fs_hz']} Hz"
            )
        except Exception as error:
            print(f"{path.name}: ERROR - {error}")

    if processed:
        print(f"\nPlots saved to {output_dir.resolve()}")


if __name__ == "__main__":
    main()

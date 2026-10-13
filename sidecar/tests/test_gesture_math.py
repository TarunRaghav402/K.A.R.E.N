"""Tests for gesture math used in orb control (gesture-to-transform mapping)."""
import pytest
import math


# ─── Gesture math (mirrors GestureProcessor.swift logic) ─────────────────────

def pinch_zoom_factor(start_span: float, end_span: float) -> float:
    """Two-finger pinch → zoom scale factor."""
    if start_span <= 0:
        return 1.0
    return end_span / start_span


def rotation_delta(dx: float, dy: float, radius: float = 1.0) -> tuple[float, float]:
    """Single-hand drag → (yaw_rad, pitch_rad) rotation deltas."""
    sensitivity = math.pi / 300.0  # radians per pixel at radius=1
    yaw   = dx * sensitivity / max(radius, 0.001)
    pitch = dy * sensitivity / max(radius, 0.001)
    return yaw, pitch


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def apply_zoom(current: float, factor: float,
               min_zoom: float = 0.3, max_zoom: float = 4.0) -> float:
    return clamp(current * factor, min_zoom, max_zoom)


# ─── Tests ────────────────────────────────────────────────────────────────────

def test_pinch_zoom_in():
    factor = pinch_zoom_factor(100.0, 200.0)
    assert factor == pytest.approx(2.0)


def test_pinch_zoom_out():
    factor = pinch_zoom_factor(200.0, 100.0)
    assert factor == pytest.approx(0.5)


def test_pinch_zoom_no_change():
    factor = pinch_zoom_factor(150.0, 150.0)
    assert factor == pytest.approx(1.0)


def test_pinch_zero_start():
    factor = pinch_zoom_factor(0.0, 100.0)
    assert factor == 1.0


def test_apply_zoom_clamps_max():
    result = apply_zoom(3.5, 2.0, max_zoom=4.0)
    assert result == pytest.approx(4.0)


def test_apply_zoom_clamps_min():
    result = apply_zoom(0.4, 0.5, min_zoom=0.3)
    assert result == pytest.approx(0.3)


def test_rotation_delta_right():
    yaw, pitch = rotation_delta(dx=100.0, dy=0.0)
    assert yaw > 0
    assert pitch == pytest.approx(0.0, abs=1e-9)


def test_rotation_delta_down():
    yaw, pitch = rotation_delta(dx=0.0, dy=100.0)
    assert pitch > 0
    assert yaw == pytest.approx(0.0, abs=1e-9)


def test_rotation_delta_symmetry():
    yaw_r, _ = rotation_delta(dx=50.0, dy=0.0)
    yaw_l, _ = rotation_delta(dx=-50.0, dy=0.0)
    assert yaw_r == pytest.approx(-yaw_l, rel=1e-6)


def test_clamp_within():
    assert clamp(0.5, 0.0, 1.0) == 0.5


def test_clamp_above():
    assert clamp(2.0, 0.0, 1.0) == 1.0


def test_clamp_below():
    assert clamp(-1.0, 0.0, 1.0) == 0.0

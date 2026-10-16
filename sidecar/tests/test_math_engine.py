"""Independent tests for safe arithmetic and spoken-number parsing."""

from decimal import Decimal

import pytest

from karen_sidecar.math_engine import (
    MathInputError,
    evaluate_math_expression,
    normalize_math_expression,
    solve_voice_math,
)


@pytest.mark.parametrize(("expression", "expected"), [
    ("10 + 20", Decimal(30)),
    ("50 - 15", Decimal(35)),
    ("12 * 8", Decimal(96)),
    ("100 / 4", Decimal(25)),
    ("17 % 5", Decimal(2)),
    ("2 ** 10", Decimal(1024)),
    ("(2 + 3) * 4", Decimal(20)),
    ("2 + 3 * 4", Decimal(14)),
    ("1.25 + 2.75", Decimal(4)),
    ("-10 + 4", Decimal(-6)),
    ("sqrt(144)", Decimal(12)),
    ("percent(10, 200)", Decimal(20)),
    ("100 / 5 + 12 * 3", Decimal(56)),
    ("2 ** 3 + 4 * 5", Decimal(28)),
    ("gcd(24, 36)", Decimal(12)),
    ("factorial(8)", Decimal(40320)),
    ("sin(radians(30))", Decimal("0.49999999999999994")),
])
def test_math_engine_examples(expression, expected):
    assert evaluate_math_expression(expression) == expected


@pytest.mark.parametrize(("phrase", "expected"), [
    ("What is 25 plus 35?", "60"),
    ("Calculate 25 plus 35.", "60"),
    ("Subtract 10 from 30.", "20"),
    ("Take away 10 from 30.", "20"),
    ("30 minus 10.", "20"),
    ("Multiply 6 by 7.", "42"),
    ("6 times 7.", "42"),
    ("Divide 20 by 4.", "5"),
    ("20 divided by 4.", "5"),
    ("20 over 4.", "5"),
    ("What is 6 divided by 7?", "0.857142857143"),
    ("6 slash 7", "0.857142857143"),
    ("Divide these two digits, 6 and 7.", "0.857142857143"),
    ("Can you divide the numbers 6 and 7?", "0.857142857143"),
    ("Please subtract 4 from 12.", "8"),
    ("What is 12 minus 4?", "8"),
    ("Multiply these two numbers, 6 and 7.", "42"),
    ("Add these digits 6 and 7.", "13"),
    ("Twenty-five added to thirty-five.", "60"),
    ("Add 25 and 35.", "60"),
    ("25 plus 35, what is the answer?", "60"),
    ("What is 12.5 multiplied by 4?", "50"),
    ("Calculate 100 divided by 4 plus 5.", "30"),
    ("Find the remainder when 17 is divided by 5.", "2"),
    ("Increase 500 by 12 percent.", "560"),
    ("Negative fifteen plus eight", "-7"),
    ("Twenty-five percent of two hundred", "50"),
    ("Square root of one hundred forty-four", "12"),
])
def test_spoken_math(phrase, expected):
    assert solve_voice_math(phrase)["answer"] == expected


def test_decimal_arithmetic_is_exact():
    assert evaluate_math_expression("0.1 + 0.2") == Decimal("0.3")


@pytest.mark.parametrize("expression", [
    "10 / 0",
    "sqrt(-1)",
    "factorial(-2)",
    "__import__('os').system('echo unsafe')",
    "2 ** 10001",
])
def test_invalid_or_unsafe_math_is_rejected(expression):
    with pytest.raises((MathInputError, ZeroDivisionError)):
        evaluate_math_expression(expression)


def test_scientific_notation_and_fraction_literals():
    assert evaluate_math_expression("1.5e2 / 3") == Decimal("50")
    assert evaluate_math_expression("1 / 2 + 1 / 2") == Decimal("1.0")


def test_multiple_spoken_operators_keep_precedence():
    assert evaluate_math_expression(normalize_math_expression("two plus three times four")) == Decimal(14)

"""Tests for Boolean expressions, numeric comparisons, and truth tables."""

import pytest

from karen_sidecar.logic_engine import (
    LogicInputError,
    evaluate_logic_expression,
    make_truth_table,
    normalize_logic_expression,
    solve_voice_logic,
)


@pytest.mark.parametrize(("expression", "expected"), [
    ("True and True", True),
    ("True and False", False),
    ("True or False", True),
    ("not True", False),
    ("10 > 5", True),
    ("10 < 5", False),
    ("5 == 5", True),
    ("5 != 5", False),
    ("True ^ False", True),
    ("not (True and False)", True),
])
def test_boolean_and_comparison_examples(expression, expected):
    assert evaluate_logic_expression(expression) is expected


@pytest.mark.parametrize(("phrase", "expected"), [
    ("Is 10 greater than 5?", True),
    ("Is 10 less than 5?", False),
    ("Evaluate true AND false.", False),
    ("Evaluate NOT true OR false.", False),
    ("Is 5 greater than 3 and 8 greater than 6?", True),
    ("True NAND False", True),
    ("True NOR False", False),
    ("True implies False", False),
    ("True equivalent to True", True),
])
def test_spoken_logic(phrase, expected):
    assert solve_voice_logic(phrase)["value"] is expected


def test_truth_table_has_all_input_rows():
    rows = make_truth_table(normalize_logic_expression("A AND B"))
    assert len(rows) == 4
    assert [row["result"] for row in rows] == [False, False, False, True]


def test_unknown_variables_are_rejected():
    with pytest.raises(LogicInputError):
        evaluate_logic_expression("A and True")

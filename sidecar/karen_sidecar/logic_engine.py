"""Safe evaluator for Boolean expressions, comparisons, and truth tables."""

from __future__ import annotations

import ast
import itertools
import re
from typing import Any

from .math_engine import MathInputError, _evaluate_node, normalize_math_expression


class LogicInputError(ValueError):
    """An expression has unsupported syntax or an undefined logic variable."""


def normalize_logic_expression(text: str) -> str:
    expression = text.strip().lower().replace("¬", " not ").replace("∧", " and ").replace("∨", " or ")
    expression = re.sub(r"^(?:hey\s+)?(?:karen|assistant)[, ]+", "", expression)
    expression = re.sub(r"^(?:evaluate|check|tell me whether|is it true that)\s+", "", expression)
    expression = re.sub(r"^is\s+(?=\d|true\b|false\b|not\b)", "", expression)
    expression = re.sub(r"\b(?:true|yes)\b", "True", expression)
    expression = re.sub(r"\b(?:false|no)\b", "False", expression)
    expression = re.sub(r"\b(?:logical )?and\b", "and", expression)
    expression = re.sub(r"\b(?:logical )?or\b", "or", expression)
    expression = re.sub(r"\bnot\b", "not", expression)
    expression = re.sub(r"\bgreater than or equal to\b", ">=", expression)
    expression = re.sub(r"\bless than or equal to\b", "<=", expression)
    expression = re.sub(r"\bgreater than\b|\bmore than\b", ">", expression)
    expression = re.sub(r"\bless than\b|\bfewer than\b", "<", expression)
    expression = re.sub(r"\bnot equal to\b|\bis not equal to\b", "!=", expression)
    expression = re.sub(r"\b(?:is )?equal to\b", "==", expression)
    expression = re.sub(r"\bequivalent to\b|\biff\b", " equivalent ", expression)
    expression = re.sub(r"\bexclusive or\b|\bxor\b", " xor ", expression)
    expression = re.sub(r"\bnand\b", " nand ", expression)
    expression = re.sub(r"\bnor\b", " nor ", expression)
    expression = re.sub(r"\bimplies\b|\bif and only if\b", " implies ", expression)
    expression = re.sub(r"\s+", " ", expression).strip(" ?.!;,:")

    # Normalize named comparison questions and embedded arithmetic in operands.
    expression = re.sub(r"\bis\s+(?=(?:>|<|==|!=))", " ", expression)
    expression = re.sub(r"\bif\s+(.+?)\s+then\s+(.+)$", r"(not (\1)) or (\2)", expression)
    expression = _rewrite_infix_special(expression, "nand", lambda a, b: f"not (({a}) and ({b}))")
    expression = _rewrite_infix_special(expression, "nor", lambda a, b: f"not (({a}) or ({b}))")
    expression = _rewrite_infix_special(expression, "implies", lambda a, b: f"(not ({a})) or ({b})")
    expression = _rewrite_infix_special(expression, "equivalent", lambda a, b: f"(({a}) == ({b}))")
    expression = re.sub(r"\bxor\b", "^", expression)

    # A natural yes/no question's leading 'is' is not an operator.
    expression = re.sub(r"^(?:is|are)\s+", "", expression)
    expression = normalize_math_expression(re.sub(r"\band\b", "andalso", expression, flags=re.I))
    expression = re.sub(r"\bandalso\b", "and", expression, flags=re.I)
    expression = re.sub(r"\btrue\b", "True", expression, flags=re.I)
    expression = re.sub(r"\bfalse\b", "False", expression, flags=re.I)
    expression = re.sub(r"\bis\s+(?=(?:>|<|==|!=))", " ", expression)
    return expression


def _rewrite_infix_special(expression: str, keyword: str, make: Any) -> str:
    # Parenthesized expressions and simple names/constants are valid operands.
    atom = r"(?:\([^()]*\)|True|False|[a-zA-Z_]\w*|\d+(?:\.\d+)?)"
    pattern = re.compile(rf"({atom})\s+{keyword}\s+({atom})", re.I)
    previous = None
    while previous != expression:
        previous = expression
        expression = pattern.sub(lambda m: make(m.group(1), m.group(2)), expression)
    return expression


def evaluate_logic_expression(expression: str, variables: dict[str, bool] | None = None) -> bool:
    if not expression or len(expression) > 2_000:
        raise LogicInputError("empty or oversized logic expression")
    try:
        tree = ast.parse(expression, mode="eval")
    except (SyntaxError, ValueError) as exc:
        raise LogicInputError("invalid logic expression") from exc
    if sum(1 for _ in ast.walk(tree)) > 250:
        raise LogicInputError("logic expression is too complex")
    values = {key.upper(): bool(value) for key, value in (variables or {}).items()}

    def visit(node: ast.AST) -> Any:
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant) and type(node.value) in (bool, int, float):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in {"True", "False"}:
                return node.id == "True"
            if node.id.upper() in values:
                return values[node.id.upper()]
            raise LogicInputError(f"unknown logic variable: {node.id}")
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not bool(visit(node.operand))
        if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
            results = [bool(visit(item)) for item in node.values]
            return all(results) if isinstance(node.op, ast.And) else any(results)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitXor):
            return bool(visit(node.left)) ^ bool(visit(node.right))
        if isinstance(node, ast.Compare):
            left = visit_comparable(node.left)
            for op, child in zip(node.ops, node.comparators):
                right = visit_comparable(child)
                if not compare(op, left, right):
                    return False
                left = right
            return True
        raise LogicInputError("unsupported logic syntax")

    def visit_comparable(node: ast.AST) -> Any:
        if isinstance(node, (ast.Constant, ast.Name)):
            return visit(node)
        try:
            return _evaluate_node(node)
        except MathInputError as exc:
            raise LogicInputError(str(exc)) from exc

    def compare(op: ast.cmpop, left: Any, right: Any) -> bool:
        operations = {
            ast.Eq: lambda: left == right, ast.NotEq: lambda: left != right,
            ast.Gt: lambda: left > right, ast.GtE: lambda: left >= right,
            ast.Lt: lambda: left < right, ast.LtE: lambda: left <= right,
        }
        operation = operations.get(type(op))
        if operation is None:
            raise LogicInputError("unsupported comparison")
        return bool(operation())

    result = visit(tree)
    if not isinstance(result, bool):
        raise LogicInputError("expected a Boolean expression")
    return result


def make_truth_table(expression: str, variables: list[str] | None = None) -> list[dict[str, bool]]:
    names = [name.upper() for name in (variables or sorted(set(re.findall(r"\b[A-Z]\b", expression.upper()))))]
    if not names or len(names) > 8 or any(not re.fullmatch(r"[A-Z]", name) for name in names):
        raise LogicInputError("truth tables support one to eight single-letter variables")
    rows: list[dict[str, bool]] = []
    for assignment in itertools.product((False, True), repeat=len(names)):
        inputs = dict(zip(names, assignment))
        rows.append({**inputs, "result": evaluate_logic_expression(expression, inputs)})
    return rows


def solve_voice_logic(text: str) -> dict[str, Any]:
    source = text.strip()
    truth_match = re.search(r"truth table for\s+(.+)$", source, re.I)
    if truth_match:
        raw_expression = truth_match.group(1)
        expression = normalize_logic_expression(raw_expression)
        rows = make_truth_table(expression)
        variables = [key for key in rows[0] if key != "result"]
        header = " | ".join(variables + ["Result"])
        lines = [header, " | ".join("---" for _ in variables + ["Result"])]
        lines.extend(" | ".join(str(row[key]) for key in variables + ["result"]) for row in rows)
        return {"expression": expression, "value": rows, "answer": "Truth table:\n" + "\n".join(lines)}
    expression = normalize_logic_expression(source)
    result = evaluate_logic_expression(expression)
    return {"expression": expression, "value": result, "answer": "True" if result else "False"}

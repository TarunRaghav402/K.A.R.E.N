"""Safe local arithmetic parser and evaluator for typed and spoken expressions."""

from __future__ import annotations

import ast
import math
import operator
import re
import statistics
from decimal import Decimal, InvalidOperation, localcontext
from typing import Any


class MathInputError(ValueError):
    """An expression is ambiguous, malformed, unsupported, or outside safe limits."""


_SMALL = {
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19,
}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
         "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}
_SCALES = {"hundred": 100, "thousand": 1_000, "million": 1_000_000,
           "billion": 1_000_000_000, "trillion": 1_000_000_000_000}
_WORD_NUMBERS = set(_SMALL) | set(_TENS) | set(_SCALES) | {
    "point", "negative", "minus", "half", "halves", "quarter",
    "quarters", "third", "thirds", "fourth", "fourths",
}
_TOKEN = re.compile(r"\d+(?:\.\d+)?(?:e[+-]?\d+)?|[a-z]+(?:-[a-z]+)*|\*\*|//|<=|>=|==|!=|[()+*/%^,<>!=.-]", re.I)


def normalize_math_expression(text: str) -> str:
    """Convert common voice phrasing to a restricted Python-like math expression."""
    source = text.lower().replace("−", "-").replace("×", "*").replace("÷", "/")
    source = re.sub(r"^(?:hey\s+)?(?:karen|assistant)[, ]+", "", source)
    source = re.sub(r",?\s*what is (?:the )?(?:answer|result|value)\s*\??$", "", source)
    source = re.sub(r",?\s*what is (?:the )?(?:answer|result|value)(?: to that)?\s*$", "", source)
    source = re.sub(r"[?!.;,]+$", "", source).strip()
    source = re.sub(r"\b(?:what is|what's|whats)\s+(?:(?:the\s+)?(?:answer|result|value)\s+to\s+)?", "", source)
    source = re.sub(r"\b(?:can|could) you\s+(?:please\s+)?", "", source)
    source = re.sub(r"\b(?:please|calculate|compute|evaluate|work out|what is|what's|whats)\b", "", source)
    source = re.sub(r"\s+(?:for me|please|sir|what is the answer)$", "", source).strip()
    # Extract the operator and operands from flexible speech, dropping filler
    # words without changing the ordinary infix-expression parser below.
    source = re.sub(r"\bslash\b", " / ", source)
    source = re.sub(r"\b(?:these|those|the|numbers|digits|number|digit|please|can you|could you|tell me|give me)\b", " ", source)
    source = re.sub(r"[,;]+", " ", source)
    source = re.sub(r"\s+", " ", source).strip()
    pair_source = re.sub(r"\b(?:these|those|the|numbers|digits|number|digit|two|please|can you|could you)\b", " ", source)
    pair_source = re.sub(r"[,;]+", " ", pair_source)
    pair_source = re.sub(r"\s+", " ", pair_source).strip()
    for pattern, template in (
        (r"\bdivide\s+(.+?)\s+(?:and|by)\s+(.+)$", r"(\1) / (\2)"),
        (r"\bmultiply\s+(.+?)\s+and\s+(.+)$", r"(\1) * (\2)"),
        (r"\badd\s+(.+?)\s+and\s+(.+)$", r"(\1) + (\2)"),
        (r"\bsubtract\s+(.+?)\s+from\s+(.+)$", r"(\2) - (\1)"),
    ):
        pair_match = re.search(pattern, pair_source)
        if pair_match:
            source = pair_match.expand(template)
            break
    source = re.sub(r"\b(?:find\s+)?(?:the\s+)?remainder when\s+(.+?)\s+is divided by\s+(.+)$", r"(\1) % (\2)", source)
    source = re.sub(r"\b(?:subtract|take away|minus)\s+(.+?)\s+from\s+(.+)$", r"(\2) - (\1)", source)
    source = re.sub(r"\b(?:multiply|times)\s+(.+?)\s+by\s+(.+)$", r"(\1) * (\2)", source)
    source = re.sub(r"\bdivide\s+(.+?)\s+by\s+(.+)$", r"(\1) / (\2)", source)
    source = re.sub(r"\bdivide\s+(.+?)\s+into\s+(.+)$", r"(\2) / (\1)", source)

    # Named functions and percentage word problems.
    source = re.sub(r"\b(?:find|calculate|what is)?\s*(?:the )?square root of\s*", "sqrt ", source)
    source = re.sub(r"\b(?:find|calculate|what is)?\s*(?:the )?cube root of\s*", "cbrt ", source)
    source = re.sub(r"\b(?:absolute value of|absolute value for)\s*", "abs ", source)
    source = re.sub(r"\b(?:factorial of)\s*", "factorial ", source)
    source = re.sub(r"\b(?:greatest common divisor|gcd) of\s*", "gcd ", source)
    source = re.sub(r"\b(?:least common multiple|lcm) of\s*", "lcm ", source)
    source = re.sub(r"\b(\d+(?:\.\d+)?)\s+percent of\s+", r"(\1 / 100) * ", source)
    source = re.sub(r"\b(\d+(?:\.\d+)?)\s+percent\s+", r"(\1 / 100) * ", source)
    source = re.sub(r"\bincrease\s+(.+?)\s+by\s+(\d+(?:\.\d+)?)\s+percent", r"(\1) * (1 + (\2 / 100))", source)
    source = re.sub(r"\bdecrease\s+(.+?)\s+by\s+(\d+(?:\.\d+)?)\s+percent", r"(\1) * (1 - (\2 / 100))", source)

    replacements = (
        (r"\b(?:raised to the power of|to the power of|raised to|power of)\b", " ** "),
        (r"\b(?:multiplied by|multiply by|times|multiplied|multiply)\b", " * "),
        (r"\b(?:divided by|divide by|divided|divide|over)\b", " / "),
        (r"\b(?:integer divided by|integer division by)\b", " // "),
        (r"\b(?:plus|add|added to|added|and then add)\b", " + "),
        (r"\b(?:minus|subtract|take away|less)\b", " - "),
        (r"\b(?:modulo|remainder|mod)\b", " % "),
        (r"\bsquared\b", " ** 2"),
        (r"\bcubed\b", " ** 3"),
        (r"\bdegrees?\b", " degrees "),
        (r"\bradians?\b", " radians "),
    )
    for pattern, replacement in replacements:
        source = re.sub(pattern, replacement, source)

    # Convert degree-aware natural trig phrases before generic spoken numbers.
    source = re.sub(r"\b(sine|sin|cosine|cos|tangent|tan) of\s*", lambda m: f"{_TRIG[m.group(1)]} ", source)

    # Convert spoken number phrases. Unrecognized words remain and are rejected
    # by the safe parser instead of being guessed or evaluated as code.
    source = re.sub(r"(?<=[a-z])-(?=[a-z])", " ", source)
    tokens = _TOKEN.findall(source)
    converted: list[str] = []
    index = 0
    previous = ""
    while index < len(tokens):
        token = tokens[index]
        lowered = token.lower()
        if re.fullmatch(r"\d+(?:\.\d+)?(?:e[+-]?\d+)?", token, re.I):
            converted.append(token)
            previous = token
            index += 1
            continue
        sign_word = lowered in {"negative", "minus"} and (not converted or previous in {"(", "+", "-", "*", "/", "**", "//", "%", ","})
        start = index + 1 if sign_word else index
        if start < len(tokens) and (tokens[start].lower() in _WORD_NUMBERS or tokens[start].lower() == "and"):
            number, end = _parse_spoken_number(tokens, start)
            converted.append(("-" if sign_word else "") + number)
            index = end
            previous = converted[-1]
            continue
        if lowered == "percent":
            converted.append("/100")
            previous = "/100"
        else:
            converted.append(token)
            previous = token
        index += 1

    expression = " ".join(converted)
    expression = re.sub(r"\b(?:evaluate|calculate|compute|please|can|could|you)\b", "", expression, flags=re.I)
    expression = re.sub(r"\b(\d+(?:\.\d+)?)\s*/100\s+of\s+(\d+(?:\.\d+)?)\b", r"(\1 / 100) * \2", expression, flags=re.I)
    expression = re.sub(r"\b(sqrt|cbrt|factorial|abs)\s+(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)", r"\1(\2)", expression, flags=re.I)
    expression = re.sub(r"\b(gcd|lcm)\s+(\d+)\s+and\s+(\d+)", r"\1(\2, \3)", expression, flags=re.I)
    expression = re.sub(r"\b(\d+(?:\.\d+)?)\s+percent of\s+(\d+(?:\.\d+)?)", r"(\1 / 100) * \2", expression, flags=re.I)
    expression = re.sub(r"\b(increase|decrease)\s+(\d+(?:\.\d+)?)\s+by\s+(\d+(?:\.\d+)?)\s+percent", lambda m: f"{m.group(2)} * (1 {'+' if m.group(1).lower() == 'increase' else '-'} {m.group(3)} / 100)", expression, flags=re.I)
    expression = re.sub(r"\b(sin|cos|tan)\s+(-?\d+(?:\.\d+)?)\s+degrees\b", r"\1(radians(\2))", expression, flags=re.I)
    expression = re.sub(r"\b(sin|cos|tan)\s+(-?\d+(?:\.\d+)?)\s+radians\b", r"\1(\2)", expression, flags=re.I)
    expression = re.sub(r"(?<=[0-9)])\s+x\s+(?=[0-9(])", " * ", expression, flags=re.I)
    expression = expression.replace("^", " ** ")
    expression = re.sub(r"\bdegrees\b", "", expression)
    expression = re.sub(r"\b(\d+(?:\.\d+)?)\s+degrees\b", r"radians(\1)", expression)
    expression = re.sub(r"\b(and|point)\b", lambda m: "." if m.group(1) == "point" else "and", expression)
    expression = re.sub(r"\s+", " ", expression).strip()
    return expression


_TRIG = {"sine": "sin", "sin": "sin", "cosine": "cos", "cos": "cos",
         "tangent": "tan", "tan": "tan"}


def _parse_spoken_number(tokens: list[str], start: int) -> tuple[str, int]:
    negative = False
    if tokens[start].lower() in {"negative", "minus"}:
        negative = True
        start += 1
    end = start
    words: list[str] = []
    while end < len(tokens):
        word = tokens[end].lower()
        if "-" in word:
            parts = word.split("-")
            if all(part in _WORD_NUMBERS for part in parts):
                tokens[end:end + 1] = parts
                word = tokens[end].lower()
        if word in _WORD_NUMBERS or word == "and":
            # Keep 'and' inside a number only when a scale precedes it.
            if word == "and" and (not words or words[-1] not in _SCALES):
                break
            words.append(word)
            end += 1
        else:
            break
    if not words:
        raise MathInputError("missing spoken number")

    fraction_suffix = words[-1]
    denominator = {"half": 2, "halves": 2, "quarter": 4, "quarters": 4,
                   "third": 3, "thirds": 3, "fourth": 4, "fourths": 4}.get(fraction_suffix)
    if denominator and len(words) == 2:
        numerator = _cardinal(words[:1])
        value = f"{numerator}/{denominator}"
    elif "point" in words:
        point_index = words.index("point")
        whole = _cardinal(words[:point_index]) if point_index else 0
        decimal_digits = "".join(str(_SMALL[w]) for w in words[point_index + 1:] if w in _SMALL and _SMALL[w] < 10)
        if not decimal_digits:
            raise MathInputError("incomplete decimal")
        value = f"{whole}.{decimal_digits}"
    else:
        value = str(_cardinal(words))
    return ("-" if negative else "") + value, end


def _cardinal(words: list[str]) -> int:
    total = current = 0
    for word in words:
        if word in _SMALL:
            current += _SMALL[word]
        elif word in _TENS:
            current += _TENS[word]
        elif word == "and":
            continue
        elif word == "hundred":
            current = max(current, 1) * 100
        elif word in _SCALES:
            total += max(current, 1) * _SCALES[word]
            current = 0
        else:
            raise MathInputError(f"unknown number word: {word}")
    return total + current


def evaluate_math_expression(expression: str) -> Any:
    if not expression or len(expression) > 2_000:
        raise MathInputError("empty or oversized expression")
    try:
        tree = ast.parse(expression, mode="eval")
    except (SyntaxError, ValueError) as exc:
        raise MathInputError("invalid expression") from exc
    if sum(1 for _ in ast.walk(tree)) > 250:
        raise MathInputError("expression is too complex")
    with localcontext() as context:
        context.prec = 50
        return _evaluate_node(tree)


def _decimal(value: Any) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise MathInputError("expected a number")
    try:
        result = value if isinstance(value, Decimal) else Decimal(str(value))
    except InvalidOperation as exc:
        raise MathInputError("invalid number") from exc
    if not result.is_finite() or result.adjusted() > 1000 or result.adjusted() < -1000:
        raise MathInputError("number is outside safe limits")
    return result


def _evaluate_node(node: ast.AST) -> Any:
    if isinstance(node, ast.Expression):
        return _evaluate_node(node.body)
    if isinstance(node, ast.Constant) and type(node.value) in (int, float):
        if len(str(node.value)) > 1000:
            raise MathInputError("number is too large")
        return _decimal(node.value)
    if isinstance(node, ast.Name) and node.id in {"pi", "e", "tau"}:
        return _decimal({"pi": "3.1415926535897932384626433832795028841971693993751",
                         "e": "2.7182818284590452353602874713526624977572470937000",
                         "tau": "6.2831853071795864769252867665590057683943387987502"}[node.id])
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        value = _decimal(_evaluate_node(node.operand))
        return value if isinstance(node.op, ast.UAdd) else -value
    if isinstance(node, ast.BinOp):
        left = _decimal(_evaluate_node(node.left))
        right = _decimal(_evaluate_node(node.right))
        operations = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
                      ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv,
                      ast.Mod: operator.mod}
        if type(node.op) in operations:
            result = operations[type(node.op)](left, right)
        elif isinstance(node.op, ast.Pow):
            if right != right.to_integral_value() or abs(right) > 10_000:
                raise MathInputError("exponent must be an integer from -10000 to 10000")
            result = left ** int(right)
        else:
            raise MathInputError("operator is not supported")
        return _decimal(result)
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_evaluate_node(item) for item in node.elts]
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name) or node.keywords:
            raise MathInputError("only supported math functions may be called")
        name = node.func.id.lower()
        args = [_evaluate_node(arg) for arg in node.args]
        return _call_function(name, args)
    raise MathInputError("expression contains unsupported syntax")


def _call_function(name: str, args: list[Any]) -> Any:
    unary_decimal = {"abs": abs, "sqrt": lambda x: _decimal(x).sqrt(),
                     "floor": lambda x: Decimal(math.floor(_decimal(x))),
                     "ceil": lambda x: Decimal(math.ceil(_decimal(x))),
                     "round": lambda x: _decimal(x).quantize(Decimal("1"))}
    if name in unary_decimal and len(args) == 1:
        value = _decimal(args[0])
        if name == "sqrt" and value < 0:
            raise MathInputError("square root of a negative number is not real")
        return unary_decimal[name](value)
    if name == "cbrt" and len(args) == 1:
        value = float(_decimal(args[0]))
        return _decimal(math.copysign(abs(value) ** (1 / 3), value))
    if name in {"sin", "cos", "tan", "asin", "acos", "atan", "log", "log10", "ln", "exp", "radians", "degrees"}:
        if not 1 <= len(args) <= 2:
            raise MathInputError(f"{name} takes one or two arguments")
        values = [float(_decimal(arg)) for arg in args]
        functions = {"sin": math.sin, "cos": math.cos, "tan": math.tan,
                     "asin": math.asin, "acos": math.acos, "atan": math.atan,
                     "log": math.log, "log10": math.log10, "ln": math.log,
                     "exp": math.exp, "radians": math.radians, "degrees": math.degrees}
        try:
            result = functions[name](*values)
        except (ValueError, OverflowError) as exc:
            raise MathInputError(f"invalid input for {name}") from exc
        if not math.isfinite(result):
            raise MathInputError("result is outside the supported range")
        return _decimal(result)
    if name in {"factorial", "fact"} and len(args) == 1:
        value = _integer(args[0])
        if not 0 <= value <= 1000:
            raise MathInputError("factorial input must be from 0 to 1000")
        return Decimal(math.factorial(value))
    if name in {"gcd", "lcm"} and len(args) >= 2:
        numbers = [_integer(arg) for arg in args]
        return Decimal(math.gcd(*numbers) if name == "gcd" else math.lcm(*numbers))
    if name in {"perm", "permutations", "comb", "combinations"} and len(args) in {1, 2}:
        n = _integer(args[0])
        r = n if len(args) == 1 else _integer(args[1])
        if not (0 <= r <= n <= 1000):
            raise MathInputError("permutation and combination inputs must satisfy 0 <= r <= n <= 1000")
        return Decimal(math.perm(n, r) if name in {"perm", "permutations"} else math.comb(n, r))
    if name == "percent" and len(args) == 2:
        return _decimal(args[0]) * _decimal(args[1]) / Decimal(100)
    if name in {"min", "max", "sum"} and args:
        values = args[0] if len(args) == 1 and isinstance(args[0], list) else args
        numbers = [_decimal(value) for value in values]
        return min(numbers) if name == "min" else max(numbers) if name == "max" else sum(numbers, Decimal(0))
    if name in {"mean", "average", "median", "mode"} and args:
        values = args[0] if len(args) == 1 and isinstance(args[0], list) else args
        numbers = [_decimal(value) for value in values]
        try:
            if name in {"mean", "average"}:
                return sum(numbers, Decimal(0)) / len(numbers)
            if name == "median":
                return _decimal(statistics.median(numbers))
            return _decimal(statistics.mode(numbers))
        except statistics.StatisticsError as exc:
            raise MathInputError("the data has no unique mode") from exc
    if name in {"is_prime", "prime"} and len(args) == 1:
        number = _integer(args[0])
        return number >= 2 and all(number % divisor for divisor in range(2, math.isqrt(number) + 1))
    if name in {"prime_factors", "factorize"} and len(args) == 1:
        number = abs(_integer(args[0]))
        if number < 2 or number > 10**12:
            raise MathInputError("prime factorization supports integers from 2 to 1 trillion")
        factors = []
        divisor = 2
        while divisor * divisor <= number:
            while number % divisor == 0:
                factors.append(Decimal(divisor))
                number //= divisor
            divisor += 1 if divisor == 2 else 2
        if number > 1:
            factors.append(Decimal(number))
        return factors
    raise MathInputError(f"unsupported function or wrong number of arguments: {name}")


def _integer(value: Any) -> int:
    number = _decimal(value)
    if number != number.to_integral_value():
        raise MathInputError("this operation requires integers")
    return int(number)


def format_result(value: Any) -> str:
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, list):
        return ", ".join(format_result(item) for item in value)
    number = _decimal(value)
    if number == number.to_integral_value():
        return str(number.quantize(Decimal("1")))
    return format(number.normalize(), ".12g")


def solve_voice_math(text: str) -> dict[str, Any]:
    expression = normalize_math_expression(text)
    if not re.search(r"\d|\b(?:pi|e|tau|sqrt|cbrt|factorial|gcd|lcm|sin|cos|tan|log|mean|median|mode|percent|prime|floor|ceil|abs)\b", expression):
        raise MathInputError("I couldn't identify numbers and an operation")
    result = evaluate_math_expression(expression)
    return {"expression": expression, "value": result, "answer": format_result(result)}

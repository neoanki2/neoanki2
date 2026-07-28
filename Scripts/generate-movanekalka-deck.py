#!/usr/bin/env python3
"""Generate MovaNeKalka.neoanki from the dictionary PDF."""

import fitz
import json
import os
import re
from collections import defaultdict

PDF_PATH = os.path.expanduser("~/Downloads/movanekalka.pdf")
DECK_ROOT = os.path.join(
    os.path.dirname(__file__), "..", "docs", "examples", "MovaNeKalka.neoanki"
)
LEFT_X = 220
HEADER_Y_MAX = 55
FOOTER_Y_MIN = 600
CYRILLIC_LETTERS = "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЮЯЄІЇҐ"
SHARD_SIZE = 500
HEADER_PHRASES = {"Так кажуть...", "А ми радимо так..."}

TRANSLIT = {
    "А": "a", "Б": "b", "В": "v", "Г": "h", "Д": "d", "Е": "e", "Ж": "zh",
    "З": "z", "Й": "j", "К": "k", "Л": "l", "М": "m", "Н": "n", "О": "o",
    "П": "p", "Р": "r", "С": "s", "Т": "t", "У": "u", "Ф": "f", "Х": "kh",
    "Ц": "ts", "Ч": "ch", "Ш": "sh", "Щ": "shch", "Ю": "yu", "Я": "ya",
    "Є": "ye", "І": "i", "Ї": "yi", "Ґ": "g", "misc": "misc",
}

PROSE_START = re.compile(
    r"^(?:"
    r"В\. ?К\.|Вислів походить|Це фраза|Цей фразеологізм|"
    r"Походження вислову|Історія|Чехи на|Державний статус|"
    r"Мова про мovу|Мова про мову|Арістотель|Етимологія|"
    r"Французьке слово|Англійська мова|Сей чудовий|За переписом|"
    r"Ми готові|Офіційний статус|статус офіційної|"
    r"Так кажуть"
    r")",
    re.IGNORECASE,
)

BIBLIOGRAPHY = re.compile(
    r"(?:"
    r"//|/ В\.|Академія,\s*20|Етимологія,\s*тлумачення|"
    r"ISBN|видавництв|Забіяка|Пономарів про|Час ії Події|"
    r"Високий замок|Опыть русско|rychloměr|rychlost|news room|"
    r"Stanko,|Marjana,|Ivanka,|design\b|Plautus|Мюller|Мюллер"
    r")",
    re.IGNORECASE,
)

MIN_BODY_SIZE = 9.8

PROSE_MARKERS = (
    "wywiad ", "dzienik", "99% людей", "сільськогосподарських",
    "зелених чоловічків", "національного лідера", "російськомовних",
    "опитаних", "Minotaur", "minotaur", "Автор вислову", "імператор",
    "Формера:", "зголоситися", "зголошення вже", "Наша українська",
    "Академія наук", "Херсонщин", "Запорозьк", "росіян –",
    "Почувши у відповідь", "русский ответ", "більшість із нас",
    "енциклопед", "Скилл", "Харибд", "Тартак", "Пономарів", "Забіяка",
    "Василенко", "Колесніченко", "Plautus",
)

CONTINUATION_ENDINGS = (
    " на", " у", " в", " з", " із", " до", " не", " але", " та", " і",
    " для", " що", " як", " при", " без", " під", " над", " між", " або",
    " вже", " ще", " лише", " цього", " собі",
)

LATIN_WORDS = re.compile(r"[A-Za-z]{2,}")
RUSSIAN_CHARS = re.compile(r"[ыэъёЪЫЭ]")
CYRILLIC_RUSSIAN = re.compile(r"\b(?:русский|російськ)\b", re.IGNORECASE)
PERCENT = re.compile(r"\d+\s*%")


def span_is_dictionary_body(span: dict) -> bool:
    font = span.get("font", "")
    if "PTSerif" in font or "Georgia" in font:
        return False
    if round(span.get("size", 0), 1) < MIN_BODY_SIZE:
        return False
    return True


def is_dictionary_page(page) -> bool:
    headers = {"left": False, "right": False}
    for block in page.get_text("dict")["blocks"]:
        if block.get("type") != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                text = span["text"].strip()
                if span["bbox"][1] > 120:
                    continue
                if text == "Так кажуть...":
                    headers["left"] = True
                if text == "А ми радимо так...":
                    headers["right"] = True
    return headers["left"] and headers["right"]


def dictionary_body_rects(page) -> list:
    rects = []
    for block in page.get_text("dict")["blocks"]:
        if block.get("type") != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                if span_is_dictionary_body(span):
                    rects.append(span["bbox"])
    return rects


def word_in_dictionary_body(cx: float, cy: float, body_rects: list) -> bool:
    for sx0, sy0, sx1, sy1 in body_rects:
        if sx0 <= cx <= sx1 and sy0 <= cy <= sy1:
            return True
    return False


def extract_rows(page):
    body_rects = dictionary_body_rects(page)
    rows = defaultdict(lambda: {"left": [], "right": []})
    for word in page.get_text("words"):
        x0, y0, x1, y1, text, *_rest = word
        if y0 < HEADER_Y_MAX or y0 > FOOTER_Y_MIN:
            continue
        if not word_in_dictionary_body((x0 + x1) / 2, (y0 + y1) / 2, body_rects):
            continue
        stripped = text.strip()
        if not stripped or stripped in HEADER_PHRASES:
            continue
        if stripped.isdigit() and len(stripped) <= 3:
            continue
        if x0 < LEFT_X:
            rows[round(y0, 0)]["left"].append(text)
        else:
            rows[round(y0, 0)]["right"].append(text)
    return rows


def extract_pairs(page):
    rows = extract_rows(page)
    pairs = []
    current_left = None
    current_right_parts = []

    for y in sorted(rows.keys()):
        left = re.sub(r"\s+", " ", " ".join(rows[y]["left"]).strip())
        right = re.sub(r"\s+", " ", " ".join(rows[y]["right"]).strip())

        if left and right:
            if current_left is not None and not current_right_parts:
                if len(current_left) > 3:
                    left = f"{current_left} {left}".strip()
            elif current_left is not None:
                pairs.append((current_left, " ".join(current_right_parts).strip()))
            current_left = left
            current_right_parts = [right]
        elif left and not right:
            if current_left is not None and not current_right_parts:
                if len(current_left) > 3:
                    current_left = f"{current_left} {left}".strip()
                else:
                    current_left = left
            elif current_left is not None:
                pairs.append((current_left, " ".join(current_right_parts).strip()))
                current_left = left
                current_right_parts = []
            else:
                current_left = left
                current_right_parts = []
        elif right and current_left is not None:
            current_right_parts.append(right)

    if current_left is not None:
        pairs.append((current_left, " ".join(current_right_parts).strip()))
    return pairs


HOMOGLYPHS = str.maketrans({
    "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "I": "І", "K": "К",
    "M": "М", "O": "О", "P": "Р", "T": "Т", "X": "Х", "Y": "У",
    "a": "а", "c": "с", "e": "е", "i": "і", "k": "к", "o": "о", "p": "р",
    "x": "х", "y": "у",
})


def has_stray_latin(text: str) -> bool:
    for match in re.finditer(r"[A-Za-z]+", text):
        if re.fullmatch(r"[IVXLCDMivxlcdm]+", match.group()):
            continue
        return True
    return False


def normalize_homoglyphs(text: str) -> str:
    if not re.search(r"[А-ЯІЇЄҐа-яіїєґ]", text):
        return text
    return text.translate(HOMOGLYPHS)


def trim_merged_answer(text: str) -> str:
    text = re.sub(r"»\d{1,3}", "»", text)
    paren_match = re.match(r"^(.+?\))\.\s+([А-ЯІЇЄҐ].*)$", text)
    if paren_match and len(paren_match.group(1)) > 10:
        return paren_match.group(1) + "."
    dot_match = re.match(r"^(.+?\.)[\s\u00a0]+([А-ЯІЇЄҐа-яіїєґ].*)$", text)
    if dot_match:
        first, second = dot_match.group(1).strip(), dot_match.group(2).strip()
        if second[0].islower() or (second[0].isupper() and len(first) > 10):
            return first
    return text


def strip_source_debris(text: str) -> str:
    text = normalize_homoglyphs(text)
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([,.;:!?])", r"\1", text)
    text = re.sub(r"\s+[А-ЯІЇЄҐґ]$", "", text)
    text = re.sub(r"\)\d{1,3}\.?", ")", text)
    text = re.sub(r"(?<=[а-яіїєґА-ЯІЇЄҐ])\d{1,3}\.?(?=\s|$|[;,)])", "", text)
    text = re.sub(r"(?<=[^\W\d_\s])\d{1,3}\.?$", "", text)
    return text.strip()


def delimiters_balanced(text: str) -> bool:
    for open_ch, close_ch in (("(", ")"), ("«", "»"), ("[", "]")):
        if text.count(open_ch) != text.count(close_ch):
            return False
    return True


def looks_like_prose(calque: str, ukrainian: str) -> bool:
    combined = f"{calque} {ukrainian}"
    if PERCENT.search(combined):
        return True
    if CYRILLIC_RUSSIAN.search(combined):
        return True
    if any(marker in combined for marker in PROSE_MARKERS):
        return True
    if re.match(r"^«[^»]+»\.?$", ukrainian.strip()):
        return True
    if re.match(r"^«[^»]+»\.?$", calque.strip()):
        return True
    if len(calque.split()) <= 3 and ukrainian.startswith("«") and len(ukrainian.split()) <= 2:
        return True
    if re.search(r":\s+\S+\s+\S+\s+\S+", calque):
        return True
    if any(calque.endswith(e) for e in CONTINUATION_ENDINGS):
        return True
    if any(ukrainian.endswith(e) for e in CONTINUATION_ENDINGS):
        return True
    if re.search(r"щині\.|області\.|краї\s+\S+\s+–", calque):
        return True
    if " – " in calque and len(calque) > 60:
        return True
    if " // " in combined or "…" in calque:
        return True
    return False


def is_valid_entry(calque: str, ukrainian: str) -> bool:
    if not calque or not ukrainian:
        return False
    if len(calque) < 3 or len(ukrainian) < 3:
        return False
    if calque in HEADER_PHRASES or ukrainian in HEADER_PHRASES:
        return False
    if calque.startswith("Так кажуть") or ukrainian.startswith("А ми радимо"):
        return False
    if ukrainian in (".", '".', '").', ".)"):
        return False
    if len(calque) > 200 or len(ukrainian) > 400:
        return False

    first = calque[0]
    if first in "([0123456789@":
        return False
    if first.isascii() and first.isalpha():
        return False
    if first.islower() or (ukrainian and ukrainian[0].islower()):
        return False

    if calque.startswith("«") and len(calque) > 80:
        return False
    if calque.endswith(("-", "–", "—")) or ukrainian.endswith(("-", "–", "—")):
        return False
    if calque.endswith((",", ";", ":")) or ukrainian.endswith((",", ";", ":")):
        return False
    if calque.endswith("…") or ukrainian.endswith("…"):
        return False

    if not delimiters_balanced(calque) or not delimiters_balanced(ukrainian):
        return False

    combined = f"{calque} {ukrainian}"
    if PROSE_START.search(calque):
        return False
    if BIBLIOGRAPHY.search(combined):
        return False
    if LATIN_WORDS.search(combined):
        return False
    if has_stray_latin(combined):
        return False
    if RUSSIAN_CHARS.search(combined):
        return False
    if re.search(r"\b\d{4}\s*р\.?\b", combined):
        return False
    if re.search(r"\d{1,3}\.\s+[А-ЯІЇЄҐ]", calque):
        return False
    if re.search(r"[а-яіїєґА-ЯІЇЄҐ]\d{1,3}\.", combined):
        return False
    if re.search(r"»\d{1,3}", combined):
        return False
    if re.search(r"\.\s+[а-яіїєґ]", ukrainian):
        return False
    if looks_like_prose(calque, ukrainian):
        return False

    if re.search(r"^[А-ЯІЇЄҐ]\s*$", ukrainian):
        return False
    if re.search(r"^[А-ЯІЇЄҐ]\s+[А-ЯІЇЄҐ]\s*$", ukrainian):
        return False

    return True


def letter_bucket(first_char: str) -> str:
    char = first_char.upper()
    if char in CYRILLIC_LETTERS:
        return char
    return "misc"


def deck_id_for_letter(letter: str) -> str:
    return "letter_" + TRANSLIT.get(letter, "misc")


def make_item(deck_id: str, calque: str, ukrainian: str) -> dict:
    return {
        "kind": "item",
        "deck": deck_id,
        "type": "DictionaryEntry",
        "fields": {
            "calque": {"text": calque, "lang": "uk"},
            "ukrainian": {"text": ukrainian, "lang": "uk"},
        },
        "tags": ["movanekalka", "ukrainian"],
    }


def main():
    deck_root = os.path.abspath(DECK_ROOT)
    items_dir = os.path.join(deck_root, "items")

    if os.path.exists(items_dir):
        for name in os.listdir(items_dir):
            os.remove(os.path.join(items_dir, name))
    else:
        os.makedirs(items_dir)

    doc = fitz.open(PDF_PATH)
    entries = []
    seen = set()
    rejected = defaultdict(int)

    for page_index in range(doc.page_count):
        page = doc[page_index]
        if not is_dictionary_page(page):
            continue
        for calque, ukrainian in extract_pairs(page):
            calque = strip_source_debris(calque)
            ukrainian = trim_merged_answer(strip_source_debris(ukrainian))
            if not is_valid_entry(calque, ukrainian):
                rejected["invalid"] += 1
                continue
            key = (calque, ukrainian)
            if key in seen:
                rejected["duplicate"] += 1
                continue
            seen.add(key)
            letter = letter_bucket(calque[0])
            if letter == "misc":
                rejected["misc"] += 1
                continue
            entries.append((letter, calque, ukrainian))

    by_letter = defaultdict(list)
    for letter, calque, ukrainian in entries:
        by_letter[letter].append((calque, ukrainian))

    parts = []
    for letter in sorted(by_letter.keys(), key=lambda x: (x == "misc", x)):
        deck_id = deck_id_for_letter(letter)
        items = by_letter[letter]
        for shard_index in range(0, len(items), SHARD_SIZE):
            shard_items = items[shard_index : shard_index + SHARD_SIZE]
            suffix = (
                ""
                if shard_index == 0 and len(items) <= SHARD_SIZE
                else f"-{shard_index // SHARD_SIZE + 1:03d}"
            )
            part_path = f"items/{deck_id}{suffix}.jsonl"
            parts.append(part_path)
            with open(os.path.join(deck_root, part_path), "w", encoding="utf-8") as handle:
                for calque, ukrainian in shard_items:
                    handle.write(
                        json.dumps(make_item(deck_id, calque, ukrainian), ensure_ascii=False) + "\n"
                    )

    decks = [{"kind": "deck", "id": "movanekalka", "name": "Мова – не калька"}]
    for letter in sorted(by_letter.keys(), key=lambda x: (x == "misc", x)):
        decks.append(
            {
                "kind": "deck",
                "id": deck_id_for_letter(letter),
                "name": f"Літера {letter}",
                "parent": "movanekalka",
            }
        )

    type_record = {
        "kind": "type",
        "id": "DictionaryEntry",
        "name": "Словниковий запис",
        "fields": [
            {"id": "calque", "name": "Так кажуть", "type": "text", "required": True},
            {"id": "ukrainian", "name": "А ми радимо", "type": "text", "required": True},
        ],
        "templates": [
            {
                "name": "Калька → Українська",
                "prompt": [{"field": "calque"}],
                "answer": [{"field": "ukrainian"}],
                "interaction": "reveal",
                "skill": {"input": "text", "output": "text", "operation": "recall"},
            }
        ],
    }

    manifest = {"kind": "neoanki", "version": 1, "root": "movanekalka", "parts": parts}
    with open(os.path.join(deck_root, "deck.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, ensure_ascii=False) + "\n")
        handle.write(json.dumps(type_record, ensure_ascii=False) + "\n")
        for deck in decks:
            handle.write(json.dumps(deck, ensure_ascii=False) + "\n")

    print(f"Generated {len(entries)} items in {len(parts)} shards across {len(by_letter)} letter decks")
    if rejected:
        print(f"Rejected: {dict(rejected)}")
    for letter in ("Ю", "Я"):
        count = len(by_letter.get(letter, []))
        print(f"  Letter {letter}: {count} items")


if __name__ == "__main__":
    main()
